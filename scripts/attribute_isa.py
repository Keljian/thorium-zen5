#!/usr/bin/env python3
"""
attribute_isa.py -- answer "where are the vector instructions, and what kind
are they", which scripts/analyze_isa.py cannot.

analyze_isa.py reports counts per ISA extension bucket (AVX512F, AVX512DQ...).
That says an instruction exists; it does not say which COMPONENT emitted it
(Skia? V8? libyuv?) or what KIND of work it does (FMA? shuffle? mask op?).
Both matter, because they decide whether a given win is ours (compiler
auto-vectorization) or stock (hand-written, runtime-dispatched SIMD).

Two passes over one streamed disassembly:

  1. EXACT histograms  -- every vector instruction, by mnemonic, by register
     width, by operation class, and by EVEX feature use (opmask / zeroing /
     broadcast). No symbolization needed, so these numbers are complete.

  2. SAMPLED attribution -- every Nth vector instruction's address is
     symbolized in one batch via llvm-symbolizer against the PDB, then the
     function name is matched to a component. Sampled because symbolizing all
     of them is slow and adds nothing: component shares are a proportion, and
     a systematic sample estimates a proportion perfectly well. The sample
     size is reported so the reader can judge the error bar themselves.

Streaming, like analyze_isa.py: chrome.dll's disassembly is ~10GB of text and
must never be held in memory.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ADDR_LINE_RE = re.compile(
    r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+)*\s*([a-zA-Z][a-zA-Z0-9.]*)\s*(.*)$")

ZMM_RE = re.compile(r"\bzmm\d+\b", re.I)
YMM_RE = re.compile(r"\bymm\d+\b", re.I)
XMM_RE = re.compile(r"\bxmm\d+\b", re.I)
KREG_RE = re.compile(r"\bk[0-7]\b", re.I)
MASK_RE = re.compile(r"\{%?k[0-7]\}")
ZERO_RE = re.compile(r"\{z\}")
BCAST_RE = re.compile(r"\{1to\d+\}")
# xmm16-31 / ymm16-31 / zmm16-31 require EVEX: the "extra 16 registers"
HIREG_RE = re.compile(r"\b[xyz]mm(1[6-9]|2\d|3[01])\b", re.I)

# Operation classes, checked in order -- first match wins.
OP_CLASSES = [
    ("fma",            r"^vf(n?)m(add|sub)"),
    ("dot_vnni",       r"^vpdp"),
    ("crypto_aes_clmul", r"^(vaes|aes|vpclmul|pclmul|sha\d)"),
    ("gather_scatter", r"^v(p?)(gather|scatter)"),
    ("convert",        r"^vcvt"),
    ("extend_pack",    r"^vp(mov[sz]x|ack|mov[bwdq])"),
    ("shuffle_permute", r"^v(perm|shuf|pshuf|palign|align|unpck|punpck|insert|extract|broadcast|pbroadcast|blend|pblend|compress|expand)"),
    ("mask_op",        r"^k(and|or|xor|not|mov|shift|test|add|unpck)"),
    ("compare_test",   r"^v(p?)(cmp|test|ptest|conflict)"),
    ("logical",        r"^v(pand|pandn|por|pxor|and|andn|or|xor|pternlog)"),
    ("shift",          r"^vp(sll|srl|sra|shld|shrd|rol|ror)"),
    ("popcount_bitalg", r"^vp(opcnt|shufbit)"),
    ("minmax_abs",     r"^v(p?)(min|max|abs)"),
    ("arithmetic",     r"^v(p?)(add|sub|mul|div|sqrt|rcp|rsqrt|avg|madd|scalef|range|reduce|getexp|getmant|fixup)"),
    ("move_loadstore", r"^v(mov|lddqu|maskmov|pmaskmov)"),
]
OP_CLASSES = [(n, re.compile(p, re.I)) for n, p in OP_CLASSES]

# Symbol -> component. Order matters: specific before generic.
COMPONENTS = [
    ("skia",        r"(^|[:_])Sk[A-Z]|skgpu::|skia::|SkOpts|sktext::|skvx::"),
    ("v8",          r"(^|\W)v8::|v8_inspector::|Builtins_|^_?v8_|::internal::Heap|Torque"),
    ("blink",       r"blink::|WebCore::|WTF::|cc::"),
    ("libyuv",      r"libyuv::|(^|\W)(I420|ARGB|NV12|YUY2)[A-Za-z]*Row"),
    ("av1_vpx_video", r"^(dav1d_|aom_|av1_|vpx_|vp8_|vp9_)"),
    ("ffmpeg",      r"^ff_"),
    ("simdutf",     r"simdutf::"),
    ("highway",     r"(^|\W)hwy::|N_AVX3"),
    ("crypto_boringssl", r"bssl::|^(aes|sha\d*|EVP_|bn_|gcm|chacha|poly1305|x25519|RSA_|EC_|CRYPTO_|OPENSSL_)"),
    ("icu",         r"^(icu_|u_|ubidi_|ucnv_|unum_|udat_)|icu::"),
    ("compression", r"^(deflate|inflate|crc32|adler32|Brotli|ZSTD_|LZ4_|zng_)"),
    ("image_codecs", r"^(jpeg_|jsimd_|jpeg|png_|WebP|VP8|opj_)|SkJpeg|SkPng|SkWebp"),
    ("protobuf",    r"google::protobuf::|^upb_"),
    ("abseil_std",  r"absl::|^std::|__std|memcpy|memset|memcmp|strlen"),
    ("base_net_mojo", r"(^|\W)(base|net|mojo|url|crypto|device|media|gpu|ui|content|services)::"),
]
COMPONENTS = [(n, re.compile(p)) for n, p in COMPONENTS]


def classify_op(mnemonic):
    for name, pat in OP_CLASSES:
        if pat.search(mnemonic):
            return name
    return "other_vector"


def classify_component(symbol):
    if not symbol or symbol == "??":
        return "unsymbolized"
    for name, pat in COMPONENTS:
        if pat.search(symbol):
            return name
    return "unattributed"


def disassemble_lines(objdump, binary):
    """Stream the disassembly; never materialise more than one line."""
    for cmd in ([objdump, "-d", "--x86-asm-syntax=intel", "-M", "intel", binary],
                [objdump, "--disassemble", "--x86-asm-syntax=intel", binary]):
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                stdin=subprocess.DEVNULL, text=True, bufsize=1 << 20)
        produced = False
        for line in proc.stdout:
            produced = True
            yield line.rstrip("\n")
        proc.stdout.close()
        err = proc.stderr.read()
        proc.stderr.close()
        rc = proc.wait()
        if produced and rc == 0:
            return
        if produced:
            print(f"ERROR: objdump exited {rc}: {err}", file=sys.stderr)
            sys.exit(1)
    print(f"ERROR: objdump produced nothing: {err}", file=sys.stderr)
    sys.exit(1)


def symbolize(symbolizer, binary, addresses):
    """One batch call. llvm-symbolizer reads addresses on stdin."""
    if not addresses:
        return {}
    payload = "".join(f"{a}\n" for a in addresses)
    try:
        r = subprocess.run([symbolizer, f"--obj={binary}", "--functions=short",
                            "--demangle", "--no-inlines"],
                           input=payload, capture_output=True, text=True, timeout=1800)
    except Exception as e:
        print(f"WARNING: symbolizer failed ({e}); attribution will be empty.", file=sys.stderr)
        return {}
    # llvm-symbolizer emits: <function>\n<file:line>\n\n  per address
    out, blocks = {}, r.stdout.split("\n\n")
    for addr, block in zip(addresses, blocks):
        lines = [l for l in block.splitlines() if l.strip()]
        out[addr] = lines[0].strip() if lines else "??"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--objdump", required=True)
    ap.add_argument("--symbolizer", required=True)
    ap.add_argument("--sample-cap", type=int, default=40000,
                    help="max addresses to symbolize (systematic sample)")
    ap.add_argument("--out-json", default="build/isa-attribution.json")
    ap.add_argument("--out-txt", default="build/isa-attribution.txt")
    ap.add_argument("--label", default=None)
    args = ap.parse_args()

    by_mnemonic, by_width, by_class, by_evex = Counter(), Counter(), Counter(), Counter()
    total_instructions = 0
    vector_total = 0
    sampled = []          # (address, mnemonic)
    avx512_total = 0

    # Two-stage sampling: collect everything up to the cap, then thin by 2x
    # whenever we exceed it, so the result stays a uniform systematic sample
    # without knowing the total in advance.
    stride = 1
    seen_since = 0

    for line in disassemble_lines(args.objdump, args.binary):
        m = ADDR_LINE_RE.match(line)
        if not m:
            continue
        total_instructions += 1
        addr, mnemonic, operands = m.groups()
        full = f"{mnemonic} {operands}"

        is_zmm = bool(ZMM_RE.search(operands))
        is_ymm = bool(YMM_RE.search(operands))
        is_xmm = bool(XMM_RE.search(operands))
        is_k = bool(KREG_RE.search(operands)) or mnemonic.lower().startswith("k")
        if not (is_zmm or is_ymm or is_xmm or is_k):
            continue

        vector_total += 1
        by_mnemonic[mnemonic.lower()] += 1
        by_width["zmm_512" if is_zmm else "ymm_256" if is_ymm else
                 "xmm_128" if is_xmm else "kmask_only"] += 1
        by_class[classify_op(mnemonic)] += 1

        evex = MASK_RE.search(full) or ZERO_RE.search(full) or BCAST_RE.search(full) \
            or HIREG_RE.search(operands) or is_k
        if evex:
            avx512_total += 1
            if MASK_RE.search(full):  by_evex["opmask_predicated"] += 1
            if ZERO_RE.search(full):  by_evex["zeroing"] += 1
            if BCAST_RE.search(full): by_evex["embedded_broadcast"] += 1
            if HIREG_RE.search(operands): by_evex["extended_regs_16_31"] += 1
            if is_k: by_evex["mask_register_use"] += 1

        seen_since += 1
        if seen_since >= stride:
            seen_since = 0
            sampled.append((addr, mnemonic.lower()))
            if len(sampled) > args.sample_cap:
                sampled = sampled[::2]      # thin, keep it uniform
                stride *= 2

    addrs = [a for a, _ in sampled]
    print(f"Symbolizing {len(addrs)} sampled addresses (1 in {stride} vector instructions)...",
          file=sys.stderr)
    symmap = symbolize(args.symbolizer, args.binary, addrs)

    comp = Counter()
    comp_by_width = {}
    for addr, mnem in sampled:
        sym = symmap.get(addr, "??")
        c = classify_component(sym)
        comp[c] += 1
        comp_by_width.setdefault(c, Counter())[classify_op(mnem)] += 1

    scale = (vector_total / len(sampled)) if sampled else 0
    result = {
        "binary": args.binary, "label": args.label,
        "total_instructions_disassembled": total_instructions,
        "vector_instructions": vector_total,
        "evex_avx512_instructions": avx512_total,
        "by_register_width": dict(by_width),
        "by_operation_class": dict(by_class.most_common()),
        "by_evex_feature": dict(by_evex.most_common()),
        "top_mnemonics": dict(by_mnemonic.most_common(60)),
        "attribution": {
            "sample_size": len(sampled),
            "sampling_stride": stride,
            "note": "component counts are ESTIMATES scaled from a systematic sample",
            "by_component_sampled": dict(comp.most_common()),
            "by_component_estimated": {k: int(v * scale) for k, v in comp.most_common()},
            "by_component_operation_mix": {k: dict(v.most_common(8)) for k, v in comp_by_width.items()},
        },
    }

    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_json).write_text(json.dumps(result, indent=2), encoding="utf-8")

    L = []
    L.append(f"Vector/ISA attribution for {args.binary}" + (f"  (label={args.label})" if args.label else ""))
    L.append("=" * 74)
    L.append(f"Total instructions disassembled : {total_instructions:,}")
    L.append(f"Vector instructions             : {vector_total:,}")
    L.append(f"  of which EVEX/AVX-512-encoded : {avx512_total:,}")
    L.append("")
    L.append("By register width (EXACT)")
    for k, v in by_width.most_common():
        L.append(f"  {k:<22} {v:>12,}  {100.0*v/max(vector_total,1):5.1f}%")
    L.append("")
    L.append("By operation class (EXACT)")
    for k, v in by_class.most_common():
        L.append(f"  {k:<22} {v:>12,}  {100.0*v/max(vector_total,1):5.1f}%")
    L.append("")
    L.append("EVEX feature use (EXACT; an instruction may use several)")
    for k, v in by_evex.most_common():
        L.append(f"  {k:<22} {v:>12,}")
    L.append("")
    L.append(f"By component (ESTIMATED from {len(sampled):,} sampled, 1 in {stride})")
    for k, v in comp.most_common():
        L.append(f"  {k:<22} {int(v*scale):>12,}  {100.0*v/max(len(sampled),1):5.1f}%")
    L.append("")
    L.append("Top 40 mnemonics (EXACT)")
    for k, v in by_mnemonic.most_common(40):
        L.append(f"  {k:<22} {v:>12,}")
    Path(args.out_txt).write_text("\n".join(L) + "\n", encoding="utf-8")

    print("\n".join(L))
    print(f"\nWrote {args.out_json} and {args.out_txt}")


if __name__ == "__main__":
    main()
