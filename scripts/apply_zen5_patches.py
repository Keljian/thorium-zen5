#!/usr/bin/env python3
"""
apply_zen5_patches.py -- add Zen 5 / AVX-512 CPU targeting to a STOCK
Chromium checkout.

Context
-------
Stock Chromium has NO x86 microarchitecture targeting. Verified directly
against Chromium 154.0.8037.17: build/config/compiler/BUILD.gn (3259 lines)
contains exactly one `-march=` reference and it is `-march=$arm_arch` for
ARM. Everything x86 is built for a generic x86-64 baseline.

So this tool does not rewrite somebody else's hardcoded -march (that was the
job when this project overlaid Thorium, which pinned
`-mllvm:-march=skylake-avx512`). It ADDS:

  1. a declare_args() block defining `use_znver5` and `use_generic_avx512`
  2. a targeting block inside config("compiler") that emits
     -march/-mtune for x64 Windows clang builds

Why cflags and not ThinLTO backend ldflags
------------------------------------------
Clang records the target CPU and feature set into the emitted bitcode as
per-function `target-cpu` / `target-features` attributes, and the ThinLTO
backend honours those attributes during codegen. Passing a backend CPU
override via `-mllvm:` is therefore not required, and which spelling LLVM's
LTO backend actually accepts (`-mcpu=` vs `-march=`) varies by version --
guessing would risk silently passing an ignored or rejected flag.

We do not guess. scripts/analyze_isa.py disassembles the built binary and
counts real AVX-512 instructions, so whether this is sufficient is a
measured question, not an assumed one. If the ISA report shows the vector
width isn't materialising, revisit this with that evidence in hand.

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
# argument; these are ours. Both default to false so an unpatched-intent
# build (the "baseline" profile) is byte-for-byte stock behaviour.
declare_args() {{
  # Target AMD Zen 5 (Ryzen 9 9950X and family) specifically: lets Clang's
  # own znver5 model select the complete ISA -- including AVX512VNNI, VBMI,
  # VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI, VAES, VPCLMULQDQ -- and Zen 5
  # scheduling, instead of a hand-maintained feature flag list.
  # A binary built with this WILL fault on any pre-Zen5 CPU. That is intended;
  # backward compatibility is explicitly not a goal of this project.
  use_znver5 = false

  # Vendor-neutral AVX-512 (the F/CD/VL/BW/DQ subset common to all AVX-512
  # parts, with generic AVX-512 scheduling). Exists purely as the comparison
  # point for use_znver5 in scripts/compare_builds.py.
  use_generic_avx512 = false
}}

'''

TARGETING_BLOCK = '''
  # --- {marker} ---
  # Applied to x64 Windows clang target builds only. Left out of the host
  # toolchain and any non-x64 toolchain on purpose: those build tools that
  # must run on the build machine and on other architectures, and must not
  # inherit a Zen 5 target.
  if (is_win && current_cpu == "x64" && is_clang && is_a_target_toolchain) {{
    assert(!(use_znver5 && use_generic_avx512),
           "use_znver5 and use_generic_avx512 are mutually exclusive -- " +
           "pick one; they set conflicting -march values.")
    if (use_znver5) {{
      cflags += [
        "-march=znver5",
        "-mtune=znver5",
      ]
    }} else if (use_generic_avx512) {{
      cflags += [
        "-march=skylake-avx512",
        "-mtune=skylake-avx512",
      ]
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
