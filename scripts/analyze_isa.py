#!/usr/bin/env python3
"""
analyze_isa.py -- Phase 4 tool: disassemble a built binary and report actual
AVX-512 (and other Zen5-relevant) instruction usage. Never assumes the
compiler emitted AVX-512 just because -march=znver5/use_avx512 was passed;
it inspects the real machine code with llvm-objdump.

Usage:
    python3 scripts/analyze_isa.py --binary C:\\thorium\\src\\out\\thorium\\chrome.dll \
        --objdump C:\\thorium\\src\\third_party\\llvm-build\\Release+Asserts\\bin\\llvm-objdump.exe \
        --pdb C:\\thorium\\src\\out\\thorium\\chrome.dll.pdb \
        --out-json build/isa-report.json --out-txt build/isa-report.txt

Notes / honesty about limitations:
  - Function attribution uses llvm-symbolizer against the PDB when available.
    Release Chrome PDBs still carry public symbols even with symbol_level=0,
    but inlining means "containing function" is the outermost symbol at that
    address, not necessarily where the vector code was written.
  - Classification is by mnemonic substring matching against llvm-objdump's
    Intel-syntax output, grouped into the ISA extension buckets the project
    asks for (AVX512F/BW/DQ/VL/VNNI/VBMI/VBMI2/BITALG/VPOPCNTDQ/IFMA/BF16,
    plus GFNI/VAES/VPCLMULQDQ as "other Zen5-relevant"). The mapping table
    below is maintained by hand against Intel's SDM opcode maps; if a
    mnemonic is missing, it will show up under "unclassified_avx512_or_zmm"
    rather than being silently dropped or mis-bucketed.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

MNEMONIC_BUCKETS = {
    # bucket -> regex matching objdump mnemonic (case-insensitive, word-ish)
    "AVX512F": r"^v(add|sub|mul|div|mov|broadcast|blend|cmp|min|max|and|or|xor|shuf|perm|extract|insert|rcp|sqrt|fmadd|fmsub|fnmadd|fnmsub|rangep|reducep|scalef|getexp|getmant|fixupimm|rndscale)[a-z]*.*z(mm)?\d+",
    "AVX512BW": r"^v(pmovm2b|pmovm2w|pcmpeqb|pcmpeqw|pcmpgtb|pcmpgtw|pblendmb|pblendmw|pmaddubsw|pmovwb|pmovswb|pmovuswb|paddb|paddw|psubb|psubw|pshufb).*z(mm)?\d+",
    "AVX512DQ": r"^v(pmullq|andpd|andps|xorpd|xorps|orpd|orps|fpclassp|reducep|rangep|extractf64x2|inserti64x2|cvttp[ds]2[qu]qq|cvtp[ds]2[qu]qq)",
    "AVX512VL": r"vex\.128|vex\.256",  # heuristic: VL suffixes rarely show directly in mnemonic; tracked via register width below instead
    "AVX512VNNI": r"^vpdpbusd|^vpdpwssd|^vpdpbusds|^vpdpwssds",
    "AVX512VBMI": r"^vpermb|^vpmultishiftqb",
    "AVX512VBMI2": r"^vpcompress[bw]|^vpexpand[bw]|^vpshld|^vpshrd",
    "AVX512BITALG": r"^vpopcnt[bw]|^vpshufbitqmb",
    "AVX512VPOPCNTDQ": r"^vpopcnt[dq]",
    "AVX512IFMA": r"^vpmadd52",
    "AVX512BF16": r"^vcvtne2ps2bf16|^vcvtneps2bf16|^vdpbf16ps",
    "GFNI": r"^vgf2p8",
    "VAES": r"^vaes",
    "VPCLMULQDQ": r"^vpclmulqdq",
}

ZMM_REGISTER_RE = re.compile(r"\bzmm\d+\b", re.IGNORECASE)
EVEX_HINT_RE = re.compile(r"\{k\d\}|\{z\}|\{1to\d+\}")  # AVX-512 mask/broadcast syntax that appears in objdump Intel output
AVX2_HINT_RE = re.compile(r"\bymm\d+\b", re.IGNORECASE)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def disassemble(objdump: str, binary: str) -> str:
    r = run([objdump, "-d", "--x86-asm-syntax=intel", "-M", "intel", binary])
    if r.returncode != 0 or not r.stdout:
        # Some llvm-objdump builds want --disassemble instead of -d, or no -M intel
        r = run([objdump, "--disassemble", "--x86-asm-syntax=intel", binary])
    if r.returncode != 0:
        print(f"ERROR running objdump: {r.stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout


ADDR_LINE_RE = re.compile(r"^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+)*\s*([a-zA-Z0-9.]+)\s*(.*)$")
SECTION_RE = re.compile(r"^Disassembly of section ([^\s:]+)")


def classify(mnemonic: str, operands: str) -> list[str]:
    full = f"{mnemonic} {operands}".lower()
    hits = []
    for bucket, pattern in MNEMONIC_BUCKETS.items():
        if bucket == "AVX512VL":
            continue  # handled via register-width heuristic below
        if re.search(pattern, full):
            hits.append(bucket)
    if not hits and (ZMM_REGISTER_RE.search(full) or EVEX_HINT_RE.search(full)):
        hits.append("unclassified_avx512_or_zmm")
    return hits


def analyze(text: str) -> dict:
    current_section = None
    bucket_counts = Counter()
    total_instructions = 0
    zmm_instructions = 0
    ymm_instructions = 0
    per_address_hits = []  # for regions report: (addr, mnemonic, buckets)

    for line in text.splitlines():
        sec_match = SECTION_RE.match(line)
        if sec_match:
            current_section = sec_match.group(1)
            continue
        m = ADDR_LINE_RE.match(line)
        if not m:
            continue
        addr, mnemonic, operands = m.groups()
        total_instructions += 1
        if ZMM_REGISTER_RE.search(operands):
            zmm_instructions += 1
        elif AVX2_HINT_RE.search(operands):
            ymm_instructions += 1
        buckets = classify(mnemonic, operands)
        for b in buckets:
            bucket_counts[b] += 1
        if buckets:
            per_address_hits.append({
                "section": current_section, "address": addr,
                "mnemonic": mnemonic, "operands": operands.strip(),
                "buckets": buckets,
            })

    return {
        "total_instructions_disassembled": total_instructions,
        "zmm_register_instructions": zmm_instructions,
        "ymm_register_instructions": ymm_instructions,
        "bucket_counts": dict(bucket_counts),
        "avx512_total": sum(v for k, v in bucket_counts.items() if k.startswith("AVX512") or k == "unclassified_avx512_or_zmm"),
        "sample_hits": per_address_hits[:2000],  # cap to keep JSON manageable; full count is in bucket_counts
        "sample_hits_truncated": len(per_address_hits) > 2000,
    }


def symbolize_addresses(symbolizer: str, binary: str, pdb: str | None, addresses: list[str]) -> dict:
    """Best-effort: map a sample of hit addresses to containing function names."""
    if not symbolizer or not Path(symbolizer).exists():
        return {"available": False, "reason": "llvm-symbolizer not found"}
    args = [symbolizer, "--obj", binary, "-f", "-p"]
    if pdb:
        args += ["--pdb", pdb]
    proc_input = "\n".join(f"0x{a}" for a in addresses)
    r = subprocess.run(args, input=proc_input, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        return {"available": False, "reason": r.stderr.strip()[-500:]}
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    return {"available": True, "resolved": dict(zip(addresses, lines))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--objdump", required=True)
    ap.add_argument("--symbolizer", default=None, help="llvm-symbolizer path, optional")
    ap.add_argument("--pdb", default=None)
    ap.add_argument("--out-json", default="build/isa-report.json")
    ap.add_argument("--out-txt", default="build/isa-report.txt")
    ap.add_argument("--label", default=None, help="e.g. 'zen5', 'baseline', 'generic-avx512'")
    args = ap.parse_args()

    binary = Path(args.binary)
    if not binary.exists():
        print(f"ERROR: binary not found: {binary}", file=sys.stderr)
        sys.exit(1)

    text = disassemble(args.objdump, str(binary))
    result = analyze(text)
    result["binary"] = str(binary)
    result["label"] = args.label
    result["objdump"] = args.objdump

    # Symbolize up to 200 of the highest-value (most specific) hits so the
    # report can say *which function* a chunk of AVX-512 code likely belongs
    # to, per the project's "containing function" requirement, without
    # spending minutes symbolizing every single hit.
    interesting = [h for h in result["sample_hits"] if any(b.startswith("AVX512") for b in h["buckets"])][:200]
    addrs = [h["address"] for h in interesting]
    sym = symbolize_addresses(args.symbolizer, str(binary), args.pdb, addrs) if addrs else {"available": False, "reason": "no AVX-512 hits sampled"}
    if sym.get("available"):
        for h in interesting:
            h["containing_function"] = sym["resolved"].get(h["address"], "unknown")
    result["symbolization"] = {"available": sym.get("available", False), "reason": sym.get("reason")}

    out_json = Path(args.out_json)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(result, indent=2))

    out_txt = Path(args.out_txt)
    with out_txt.open("w") as f:
        f.write(f"ISA report for {binary} (label={args.label})\n")
        f.write("=" * 70 + "\n")
        f.write(f"Total instructions disassembled: {result['total_instructions_disassembled']}\n")
        f.write(f"Instructions using ZMM (512-bit) registers: {result['zmm_register_instructions']}\n")
        f.write(f"Instructions using YMM (256-bit) registers: {result['ymm_register_instructions']}\n")
        f.write(f"Total classified AVX-512-family instructions: {result['avx512_total']}\n\n")
        f.write("By ISA extension bucket:\n")
        for bucket, count in sorted(result["bucket_counts"].items(), key=lambda kv: -kv[1]):
            f.write(f"  {bucket:22s} {count}\n")
        f.write(f"\nSymbolization available: {result['symbolization']['available']}")
        if not result['symbolization']['available']:
            f.write(f" ({result['symbolization']['reason']})")
        f.write("\n")

    print(f"Wrote {out_json} and {out_txt}")
    print(f"AVX-512-family instructions found: {result['avx512_total']} / {result['total_instructions_disassembled']} total")


if __name__ == "__main__":
    main()
