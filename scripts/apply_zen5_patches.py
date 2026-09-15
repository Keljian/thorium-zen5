#!/usr/bin/env python3
"""
apply_zen5_patches.py -- add Zen 5 / AVX-512 CPU targeting to a STOCK
Chromium checkout.

Context
-------
Stock Chromium has NO x86 microarchitecture targeting. Verified directly
against Chromium 154.0.8037.17: build/config/compiler/BUILD.gn contains
exactly one `-march=` reference and it is `-march=$arm_arch` for ARM.
Everything x86 is built for a generic x86-64 baseline.

So this tool does not rewrite somebody else's hardcoded -march. It ADDS:

  1. a declare_args() block defining the zen5_* arguments
  2. a targeting block inside config("compiler") that emits -march/-mtune
     for x64 Windows clang builds

THE TOOLCHAIN BUG: -mtune=znver* breaks ThinLTO
-----------------------------------------------
On this toolchain (Chromium 154, bundled clang 24.0.0git, Windows x64,
ThinLTO, is_official_build) the AMD Zen SCHEDULING MODEL miscompiles in the
LTO backend. It is not an AVX-512 problem and not a znver5 problem.

Isolated by holding the instruction set constant and varying only -mtune,
building net/tools/root_store_tool (2.5k steps, ~2 min) for each cell:

    -march              -mtune            result
    ------------------  ----------------  ---------------------------
    skylake-avx512      skylake-avx512    PASS
    skylake-avx512      znver4            FAIL
    znver4 (AVX512 off) znver4            FAIL   <- entire AVX-512
                                                    extension set disabled
                                                    via -mno-*, still fails
    znver4              skylake-avx512    PASS
    znver5              skylake-avx512    PASS
    znver4              generic           PASS
    znver5              generic           PASS

Every failure has AMD scheduling; every pass does not. The instruction set
is irrelevant -- the third row keeps -mtune=znver4 with every AVX-512
extension switched off and still fails.

The failure has two faces, both from the LTO backend:
  1. lld-link: error: <unknown>:0: Missing .seh_endepilogue in <fn>
     -- malformed Windows SEH unwind data.
  2. ~20 undefined symbols, all from base/logging.cc and its perfetto
     trace-event companions, referenced by whole-program-devirtualization
     branch funnels (__typeid_..._branch_funnel).
These are INDEPENDENT: disabling Windows unwind v2 removes (1) and leaves
(2) untouched. Fixing -mtune removes both, which is why no unwind-v2
workaround is needed (zen5_winunwindv2 defaults to "", clang's default).

WHY -mtune=generic AND NOT -mtune=skylake-avx512
------------------------------------------------
Both build. Only one of them actually emits 512-bit code. prefer-256-bit is
a TUNING feature in LLVM, so an Intel -mtune silently suppresses all
512-bit vectorization. Measured by counting registers in the emitted
assembly for a vectorizable loop:

    -march / -mtune                 zmm    ymm
    ------------------------------  ----   ----
    znver5 / znver5  (unbuildable)    72     18
    znver5 / skylake-avx512            0     72   <- no 512-bit code at all
    znver5 / generic                  72     18   <- identical to intended
    skylake-avx512 / skylake-avx512    0     72
    (stock, no -march)                 0      0

-mtune=generic reproduces the intended codegen exactly. What is lost is
Zen 5's instruction scheduling model only -- the full ISA, 512-bit
vectorization, PGO and ThinLTO are all intact.

Set zen5_mtune back to "znver5" once LLVM fixes this; the failure is loud
(link error), never silent.

Corrections to earlier revisions of this file
---------------------------------------------
Two claims previously asserted here were wrong and have been retracted:
  * "-march=znver5 miscompiles, use znver4" -- no. znver4 fails identically.
    The original evidence came from a single small link target that happened
    not to contain the triggering code.
  * "the ThinLTO backend flag -mllvm:-march is REQUIRED" -- no. Re-linking
    the same target with it removed, against a COLD ThinLTO cache,
    reproduces the failure identically. See zen5_lto_backend_march.

Both errors traced to the same methodological trap: -mllvm flags are NOT
part of LLVM's ThinLTO cache key, so changing one and relinking silently
reuses cached codegen and "reproduces" the previous result in ~3 seconds.
Every measurement above used a fresh per-variant cache directory.

scripts/analyze_isa.py measures the AVX-512 actually present in the
finished binary -- flags being accepted is not the same as them paying off.

Exit codes
----------
    0  applied (or already applied -- this is idempotent)
    3  an anchor was not found: upstream changed shape. NOTHING is written.
       build.ps1 configure treats this as a hard stop so no build is ever
       attempted from a half-patched tree.
"""

import argparse
import difflib
import sys
from pathlib import Path

MARKER = "thorium-zen5: Zen 5 CPU targeting"

DECLARE_ARGS_BLOCK = '''# --- {marker} (declare_args) ---
# Added by thorium-zen5. Stock Chromium has no microarchitecture-targeting
# argument; these are ours. All default to the values that reproduce stock
# behaviour so the "baseline" profile is byte-for-byte unmodified Chromium.
declare_args() {{
  # Target AMD Zen 5 (Ryzen 9 9950X and family) specifically: lets Clang's
  # own model select the complete ISA -- including AVX512VNNI, VBMI, VBMI2,
  # BITALG, VPOPCNTDQ, IFMA, BF16, GFNI, VAES, VPCLMULQDQ -- and AMD
  # scheduling, instead of a hand-maintained feature flag list.
  # A binary built with this WILL fault on any pre-Zen5 CPU. That is intended;
  # backward compatibility is explicitly not a goal of this project.
  use_znver5 = false

  # Which -march the zen5 profile emits -- the INSTRUCTION SET.
  #
  # znver5 is safe. The toolchain bug documented at the top of this file is
  # in the -mtune scheduling model, not the ISA: znver4 and znver5 behave
  # identically, and disabling the entire AVX-512 extension set does not
  # avoid it. So this targets Zen 5 fully.
  zen5_march = "znver5"

  # Vendor-neutral AVX-512 (the F/CD/VL/BW/DQ subset common to all AVX-512
  # parts). NOTE: measured to emit NO 512-bit code at all -- clang defaults
  # skylake-avx512 to prefer-vector-width=256. Kept only as a comparison
  # point for scripts/compare_builds.py; it is not "the AVX-512 build".
  use_generic_avx512 = false

  # Windows x64 unwind v2 mode for CPU-targeted builds: "", "disabled",
  # "best-effort" or "required". "" leaves clang's default in place.
  #
  # Defaults to "" -- NO workaround. This exists because the
  # "Missing .seh_endepilogue" half of the -mtune=znver* bug can be
  # suppressed by setting this to "disabled", and that was briefly the
  # intended fix. It is not needed: with zen5_mtune = "generic" the build
  # is clean at clang's DEFAULT unwind-v2 setting (verified -- the same
  # canary target builds exit=0 with this at "" and at "disabled").
  #
  # Keeping the default means we do not switch off a Windows feature we do
  # not have to. Unwind v2 is unwind METADATA (it records epilogue
  # boundaries so the OS unwinder need not emulate epilogues) rather than an
  # exploit mitigation, but it is adjacent to CET shadow-stack unwinding and
  # this build links /CETCOMPAT, so leaving it alone is the conservative
  # choice. Retained as a knob only for diagnosing this class of failure.
  zen5_winunwindv2 = ""

  # Max vector width for CPU-targeted builds ("" = the target's default,
  # otherwise e.g. "256" or "512").
  zen5_prefer_vector_width = ""

  # -mtune for CPU-targeted builds -- the SCHEDULING MODEL.
  # "" means "same as zen5_march".
  #
  # MUST NOT be znver4/znver5 on this toolchain: that is the actual bug (see
  # the header of this file for the full matrix). "generic" is the correct
  # workaround rather than an Intel -mtune, because prefer-256-bit is a
  # TUNING feature -- -mtune=skylake-avx512 builds fine but emits ZERO
  # 512-bit instructions, silently discarding the entire point of the build.
  # "generic" reproduces the intended znver5 codegen exactly (measured:
  # zmm 72 / ymm 18, same as znver5/znver5).
  #
  # Cost of the workaround: Zen 5 instruction scheduling only. The ISA,
  # 512-bit vectorization, PGO and ThinLTO are unaffected. Restore to
  # "znver5" once LLVM fixes this -- the failure is a link error, not
  # silent.
  zen5_mtune = "generic"

  # Cap the SLP vectorizer's register size (bits) for CPU-targeted builds.
  # "" leaves it at the target default.
  #
  # Works around an X86 instruction-selection gap in clang 24: with 512-bit
  # vectors enabled the backend cannot select
  #     v4i64 = zero_extend_vector_inreg
  # and aborts. Isolated to the SLP vectorizer specifically -- see
  # docs/TOOLCHAIN-BUGS.md BUG-3.
  #
  # Preferred over -mprefer-vector-width=256 because it is far narrower:
  # measured on a file with both an _mm512 intrinsic and an auto-vectorizable
  # loop, this emits zmm 38 / ymm 8 -- IDENTICAL to the unrestricted 512-bit
  # build -- whereas prefer-vector-width=256 drops to zmm 6 / ymm 32. Loop
  # vectorization and explicit intrinsics keep full 512-bit width; only
  # straight-line SLP vectorization is capped.
  #
  # Applied as an LDFLAG under ThinLTO: the vectorizers run in the LTO
  # backend (post-link), not the pre-link compile, so a cflag would not
  # reach them. Applied as a cflag when ThinLTO is off.
  #
  # NOTE: -mllvm flags are NOT part of LLVM's ThinLTO cache key. After
  # changing this you MUST delete out/<profile>/thinlto-cache or the link
  # will silently reuse the previous codegen.
  zen5_slp_max_reg_size = ""

  # Escape hatches for bisecting toolchain problems (see TOOLCHAIN-BUGS.md).
  # Extra cflags appended to CPU-targeted builds, e.g. [ "-mno-avx512vnni" ].
  # Exists so an individual ISA feature can be bisected without editing this
  # file; see docs/TOOLCHAIN-BUGS.md.
  zen5_extra_target_cflags = []

  # Extra ldflags appended to CPU-targeted builds, e.g.
  # [ "-mllvm:-some-backend-flag" ]. Because the vectorizers and instruction
  # selection run in the ThinLTO backend, link-time -mllvm flags are how you
  # reach codegen in this build -- cflags do not get there.
  zen5_extra_target_ldflags = []

  # Whether to also pass -march to the ThinLTO backend via -mllvm.
  #
  # UNVERIFIED. An earlier revision of this file asserted this was REQUIRED,
  # on the evidence of a link that failed without it. That evidence has since
  # been retracted: re-linking the same target with the flag removed and a
  # COLD ThinLTO cache reproduces the failure identically, so the flag was
  # never what fixed it. It is kept on because the bitcode's per-function
  # target-cpu attributes are believed sufficient but that has not been
  # measured here; settle it with scripts/analyze_isa.py, not by reasoning.
  zen5_lto_backend_march = true
}}

'''

TARGETING_BLOCK = '''
  # --- {marker} ---
  # x64 Windows clang builds only.
  #
  # NOTE on scope, verified against the generated ninja for Chromium 154:
  # this is NOT target-only. On a non-cross Windows x64 build the host and
  # target toolchains coincide, so is_a_target_toolchain is also true for
  # win_clang_x64_host_* and the rust host build tools, and they receive
  # these flags as well. That is acceptable HERE only because those tools are
  # built and run on the same Zen 5 machine, and backward compatibility is
  # explicitly not a goal of this project. Do not copy this to a cross build
  # or to anything that ships build tools to other machines.
  if (is_win && current_cpu == "x64" && is_clang && is_a_target_toolchain) {{
    assert(!(use_znver5 && use_generic_avx512),
           "use_znver5 and use_generic_avx512 are mutually exclusive -- " +
           "pick one; they set conflicting -march values.")

    # Toolchain workarounds, applied ONLY when CPU targeting is on so the
    # baseline profile stays byte-for-byte stock. See docs/TOOLCHAIN-BUGS.md.
    if (use_znver5 || use_generic_avx512) {{
      if (zen5_winunwindv2 != "") {{
        cflags += [ "/clang:-fwinx64-eh-unwindv2=$zen5_winunwindv2" ]
      }}
      if (zen5_prefer_vector_width != "") {{
        cflags += [ "-mprefer-vector-width=$zen5_prefer_vector_width" ]
      }}
      cflags += zen5_extra_target_cflags
      ldflags += zen5_extra_target_ldflags

      if (zen5_slp_max_reg_size != "") {{
        if (use_thin_lto) {{
          ldflags += [ "-mllvm:-slp-max-reg-size=$zen5_slp_max_reg_size" ]
        }} else {{
          cflags += [
            "-mllvm",
            "-slp-max-reg-size=$zen5_slp_max_reg_size",
          ]
        }}
      }}
    }}

    if (use_znver5) {{
      _mtune = zen5_march
      if (zen5_mtune != "") {{
        _mtune = zen5_mtune
      }}
      cflags += [
        "-march=$zen5_march",
        "-mtune=$_mtune",
      ]
      if (use_thin_lto && zen5_lto_backend_march) {{
        ldflags += [ "-mllvm:-march=$zen5_march" ]
      }}
    }} else if (use_generic_avx512) {{
      _mtune = "skylake-avx512"
      if (zen5_mtune != "") {{
        _mtune = zen5_mtune
      }}
      cflags += [
        "-march=skylake-avx512",
        "-mtune=$_mtune",
      ]
      if (use_thin_lto && zen5_lto_backend_march) {{
        ldflags += [ "-mllvm:-march=skylake-avx512" ]
      }}
    }}
  }}
  # --- end {marker} ---
'''


def already_applied(text: str) -> bool:
    return MARKER in text


def apply_edits(src_dir: Path, dry_run: bool = False):
    """Returns (changed_files, diffs). Raises SystemExit(3) on a missing anchor."""
    target = src_dir / "build" / "config" / "compiler" / "BUILD.gn"
    if not target.exists():
        print(f"ERROR: {target} does not exist -- is this a Chromium checkout?", file=sys.stderr)
        sys.exit(3)

    original = target.read_text(encoding="utf-8", errors="surrogateescape")

    if already_applied(original):
        print(f"Already patched (marker present): {target}")
        return [], {}

    text = original

    # --- Edit 1: declare_args() immediately BEFORE config("compiler")
    anchor1 = 'config("compiler") {\n  asmflags = []\n'
    n1 = text.count(anchor1)
    if n1 != 1:
        print(
            f"ERROR: anchor for the declare_args() insertion matched {n1} times "
            f"(expected exactly 1) in {target}.\n"
            f"Anchor was:\n{anchor1!r}\n"
            "Upstream Chromium changed shape. Nothing has been written. "
            "Re-derive the anchor against this checkout and update EDITS.",
            file=sys.stderr,
        )
        sys.exit(3)
    text = text.replace(anchor1, DECLARE_ARGS_BLOCK.format(marker=MARKER) + anchor1, 1)

    # --- Edit 2: targeting block right after the flag-list initialisers
    anchor2 = "  ldflags = []\n  defines = []\n  configs = []\n"
    n2 = text.count(anchor2)
    if n2 != 1:
        print(
            f"ERROR: anchor for the targeting block matched {n2} times "
            f"(expected exactly 1) in {target}.\n"
            f"Anchor was:\n{anchor2!r}\n"
            "Upstream Chromium changed shape. Nothing has been written.",
            file=sys.stderr,
        )
        sys.exit(3)
    text = text.replace(anchor2, anchor2 + TARGETING_BLOCK.format(marker=MARKER), 1)

    # Cheap structural sanity check: balanced braces should be unchanged by an
    # insertion of balanced text.
    if text.count("{") - text.count("}") != original.count("{") - original.count("}"):
        print("ERROR: brace balance changed after patching -- refusing to write.", file=sys.stderr)
        sys.exit(3)

    diff = "\n".join(
        difflib.unified_diff(
            original.splitlines(), text.splitlines(),
            fromfile=f"a/build/config/compiler/BUILD.gn",
            tofile=f"b/build/config/compiler/BUILD.gn",
            lineterm="",
        )
    )

    if not dry_run:
        target.write_text(text, encoding="utf-8", errors="surrogateescape")
        print(f"Patched {target}")

    return [target], {"build/config/compiler/BUILD.gn": diff}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--patches-dir", default=None)
    ap.add_argument("--capture-diffs", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    src_dir = Path(args.src_dir)
    changed, diffs = apply_edits(src_dir, dry_run=args.dry_run)

    if args.capture_diffs and args.patches_dir and diffs:
        pdir = Path(args.patches_dir)
        pdir.mkdir(parents=True, exist_ok=True)
        for rel, diff in diffs.items():
            out = pdir / (rel.replace("/", "_") + ".diff")
            out.write_text(diff + "\n", encoding="utf-8")
            print(f"Wrote {out}")

    if not changed:
        print("No changes needed.")
    print("zen5 patches OK.")
    sys.exit(0)


if __name__ == "__main__":
    main()
