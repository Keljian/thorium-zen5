#!/usr/bin/env python3
"""
apply_zen5_patches.py -- Phase 2 tool: apply the Zen5 (znver5) compiler
targeting changes to a real, synced Chromium+Thorium checkout, and capture
the result as literal unified-diff files under patches/zen5/.

WHY THIS EXISTS INSTEAD OF HAND-WRITTEN .patch FILES
-----------------------------------------------------
Thorium's own AVX-512 build (other/AVX512/win_AVX512_args.gn) hardcodes the
ThinLTO backend's -march to "skylake-avx512" in three source files, and only
enables the "least common denominator" AVX-512 feature subset (F/CD/VL/BW/DQ)
-- explicitly NOT tuned for any specific vendor/microarchitecture, per that
file's own comments. This script adds a new, additive `use_znver5` GN arg
and, everywhere Thorium currently special-cases `use_avx2`/`use_avx512` for
compiler/linker flags, inserts a preferred `if (use_znver5) { ... } else`
branch ahead of it that uses "-march=znver5 -mtune=znver5" (Windows:
"/clang:-march=znver5 /clang:-mtune=znver5") instead of a hand-maintained
AVX-512 feature-flag list -- so Clang's own znver5 target model decides the
complete, correct ISA and scheduling. Stock use_avx2/use_avx512 behavior
(including the "generic-avx512" comparison profile) is left completely
untouched when use_znver5=false.

Edits are found by locating a small number of *exact, distinctive compiler
flag string literals* (e.g. "-mllvm:-march=skylake-avx512") that are exact
copy-pasted quotes from the real, inspected source (see build/audit.json
and docs/ARCHITECTURE.md for the inspection trail), then inserting new text
immediately before the nearest enclosing `if (use_avxNNN) {` statement --
turning `if (X) { ... }` into `if (use_znver5) { <zen5 flags> } else if (X)
{ ... }`. This is robust to upstream reformatting of the *interior* of a
block (indentation, line wrapping, trailing commas) because it never
rewrites that interior text, only the code immediately surrounding an exact
flag literal.

This script is idempotent: re-running it on an already-patched tree is a
no-op (each edit checks whether the marker is already preceded by an
`if (use_znver5)` guard within a short window before touching anything).

Usage:
    python3 scripts/apply_zen5_patches.py --src-dir C:\\thorium\\src [--dry-run] [--capture-diffs]

Exit codes:
    0  all edits applied (or already applied) successfully
    1  src dir not found
    3  one or more expected flag literals were NOT found -- STOP, do not
       guess; upstream Thorium's compiler flag files have changed shape and
       the patches need re-authoring by hand against the new source. This
       is the "detects patch conflicts, stops rather than silently
       resolving conflicts incorrectly" requirement from the project spec.
"""
import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Edit:
    relpath: str          # file relative to src-dir
    marker: str            # exact, distinctive literal that must be present
    enclosing_if: str       # the literal "if (...) {" text to insert before
    insertion: str          # text inserted before enclosing_if (see below)
    description: str        # human-readable, for patches/zen5/README.md and logs


def znver5_guard(body: str, indent: str) -> str:
    """Build `if (use_znver5) {\n<indented body>\n<indent>} else ` """
    body_indent = indent + "  "
    return f"if (use_znver5) {{\n{body_indent}{body}\n{indent}}} else "


EDITS = [
    # --- build/config/compiler/BUILD.gn -------------------------------
    Edit(
        relpath="build/config/compiler/BUILD.gn",
        marker='"-mllvm:-march=haswell"',
        enclosing_if="if (use_avx2) {",
        insertion=znver5_guard(
            'cflags += [ "/clang:-march=znver5", "/clang:-mtune=znver5", ]\n'
            '{indent}  ldflags += [ "-mllvm:-march=znver5", ]', "      "),
        description="Windows x64 branch: AVX2 codepath's ThinLTO -march=haswell",
    ),
    Edit(
        relpath="build/config/compiler/BUILD.gn",
        marker='"-mllvm:-march=skylake-avx512"',
        enclosing_if="if (use_avx512) {",
        insertion=znver5_guard(
            'cflags += [ "/clang:-march=znver5", "/clang:-mtune=znver5", ]\n'
            '{indent}  ldflags += [ "-mllvm:-march=znver5", ]', "      "),
        description="Windows x64 branch: AVX-512 codepath's ThinLTO -march=skylake-avx512 (root cause)",
    ),
    Edit(
        relpath="build/config/compiler/BUILD.gn",
        marker='"-Wl,-mllvm,-march=haswell"',
        enclosing_if="if (use_avx2) {",
        insertion=znver5_guard(
            'cflags += [ "-march=znver5", "-mtune=znver5", ]\n'
            '{indent}  ldflags += [ "-march=znver5", "-mtune=znver5", "-Wl,-mllvm,-march=znver5", ]', "      "),
        description="Linux/Mac x64 branch (unused on this Windows-only project, patched for tree consistency)",
    ),
    Edit(
        relpath="build/config/compiler/BUILD.gn",
        marker='"-Wl,-mllvm,-march=skylake-avx512"',
        enclosing_if="if (use_avx512) {",
        insertion=znver5_guard(
            'cflags += [ "-march=znver5", "-mtune=znver5", ]\n'
            '{indent}  ldflags += [ "-march=znver5", "-mtune=znver5", "-Wl,-mllvm,-march=znver5", ]', "      "),
        description="Linux/Mac x64 branch (unused on this Windows-only project, patched for tree consistency)",
    ),
    # --- build/config/win/BUILD.gn -------------------------------------
    Edit(
        relpath="build/config/win/BUILD.gn",
        marker='"/clang:-mavx512f"',
        enclosing_if="if (use_avx512) {",
        insertion=znver5_guard(
            'cflags += [\n'
            '{indent}    "-march=znver5",\n'
            '{indent}    "-mtune=znver5",\n'
            '{indent}    "/clang:-march=znver5",\n'
            '{indent}    "/clang:-mtune=znver5",\n'
            '{indent}  ]', "      "),
        description="cl.exe-wrapper cflags block (no march= previously set here at all)",
    ),
    Edit(
        relpath="build/config/win/BUILD.gn",
        marker='"-mllvm:-march=haswell"',
        enclosing_if="if (use_avx2) {",
        insertion=znver5_guard('ldflags += [ "-mllvm:-march=znver5", ]', "    "),
        description="Release/non-component build ThinLTO backend march (AVX2 codepath)",
    ),
    Edit(
        relpath="build/config/win/BUILD.gn",
        marker='"-mllvm:-march=skylake-avx512"',
        enclosing_if="if (use_avx512) {",
        insertion=znver5_guard('ldflags += [ "-mllvm:-march=znver5", ]', "    "),
        description="Release/non-component build ThinLTO backend march (AVX-512 codepath, root cause)",
    ),
    # --- v8/BUILD.gn -----------------------------------------------------
    Edit(
        relpath="v8/BUILD.gn",
        marker='"/clang:-mavx512f"',
        enclosing_if="if (use_avx512) {",
        insertion=znver5_guard('cflags += [ "/clang:-march=znver5", "/clang:-mtune=znver5", ]', "      "),
        description="V8's own compile units (Windows path) -- otherwise V8 keeps generic AVX-512 flags",
    ),
    Edit(
        relpath="v8/BUILD.gn",
        marker='"-mavx512f"',
        enclosing_if="if (use_avx512) {",
        insertion=znver5_guard('cflags += [ "-march=znver5", "-mtune=znver5", ]', "        "),
        description="V8's own compile units (non-Windows path, unused here, patched for consistency)",
    ),
]

DECLARE_ARG_FILE = "build/config/compiler_opt.gni"
DECLARE_ARG_ANCHOR = "  use_avx512 = false\n}"
DECLARE_ARG_INSERTION = '''  use_avx512 = false

  # Zen 5 (znver5) profile -- added by thorium-zen5's patches/zen5, not a
  # stock Thorium arg. When true, every use_avx2/use_avx512 compiler and
  # linker flag call site instead emits "-march=znver5 -mtune=znver5" (or
  # the clang-cl "/clang:" spelling on Windows), letting Clang's own znver5
  # target model pick the complete, correct Zen 5 ISA and scheduling model
  # instead of a hand-maintained AVX-512 feature-flag list. Requires
  # use_avx512 = true (see gn/win_zen5_args.gn) and an LLVM new enough to
  # recognize znver5 (verified by scripts/audit_build.py before build).
  use_znver5 = false
}'''

ASSERT_BLOCK = '''
# --- Zen 5 (znver5) profile sanity checks (added by patches/zen5) ---
if (use_znver5) {
  assert(use_avx512, "use_znver5 requires use_avx512 = true (see gn/win_zen5_args.gn).")
  assert(target_cpu == "x64", "use_znver5 requires target_cpu == \\"x64\\".")
}
'''


def load(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def already_applied(text: str, marker_pos: int, enclosing_if_pos: int) -> bool:
    # This edit inserts "if (use_znver5) { ... } else " *immediately*
    # (contiguously, no gap) before `enclosing_if_pos`. So on a second run,
    # the edit is already applied iff the text immediately preceding
    # enclosing_if_pos ends with exactly that "} else " tail -- checking a
    # wider window would false-positive on an unrelated sibling znver5
    # guard inserted earlier in the same file (e.g. the avx2 block's guard
    # sitting a few lines above the avx512 block's own, still-unpatched,
    # "if (use_avx512) {").
    return text[:enclosing_if_pos].endswith("} else ")


def apply_edit(text: str, edit: Edit) -> tuple[str, str]:
    """Returns (new_text, status) where status in {"applied","already","not_found"}."""
    marker_pos = text.find(edit.marker)
    if marker_pos == -1:
        return text, "not_found"

    if_pos = text.rfind(edit.enclosing_if, 0, marker_pos)
    if if_pos == -1:
        return text, "not_found"

    if already_applied(text, marker_pos, if_pos):
        return text, "already"

    # Determine indentation of the enclosing if line.
    line_start = text.rfind("\n", 0, if_pos) + 1
    indent = text[line_start:if_pos]

    insertion_text = edit.insertion.replace("{indent}", indent)
    new_text = text[:if_pos] + insertion_text + text[if_pos:]
    return new_text, "applied"


def patch_declare_args(text: str) -> tuple[str, str]:
    if "use_znver5" in text:
        return text, "already"
    if DECLARE_ARG_ANCHOR not in text:
        return text, "not_found"
    new_text = text.replace(DECLARE_ARG_ANCHOR, DECLARE_ARG_INSERTION, 1)
    if ASSERT_BLOCK.strip() not in new_text:
        new_text = new_text.rstrip("\n") + "\n" + ASSERT_BLOCK
    return new_text, "applied"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--capture-diffs", action="store_true",
                     help="After applying, run `git diff` per file and write patches/zen5/NNNN-*.patch")
    ap.add_argument("--patches-dir", default=None)
    args = ap.parse_args()

    src_dir = Path(args.src_dir)
    if not (src_dir / "build" / "config" / "BUILDCONFIG.gn").exists():
        print(f"ERROR: {src_dir} does not look like a Chromium src checkout.", file=sys.stderr)
        sys.exit(1)

    failures = []
    touched_files = set()

    # 1. declare_args edit first (compiler_opt.gni)
    gni_path = src_dir / DECLARE_ARG_FILE
    text = load(gni_path)
    new_text, status = patch_declare_args(text)
    print(f"[{status:9}] {DECLARE_ARG_FILE} :: add use_znver5 declare_arg + sanity asserts")
    if status == "not_found":
        failures.append((DECLARE_ARG_FILE, "declare_args anchor"))
    elif status == "applied" and not args.dry_run:
        gni_path.write_text(new_text, encoding="utf-8")
        touched_files.add(DECLARE_ARG_FILE)

    # 2. per-file marker edits, grouped so we only read/write each file once
    by_file: dict[str, str] = {}
    for edit in EDITS:
        if edit.relpath not in by_file:
            by_file[edit.relpath] = load(src_dir / edit.relpath)

    for edit in EDITS:
        text = by_file[edit.relpath]
        new_text, status = apply_edit(text, edit)
        print(f"[{status:9}] {edit.relpath} :: {edit.description}")
        if status == "not_found":
            failures.append((edit.relpath, edit.marker))
        elif status == "applied":
            by_file[edit.relpath] = new_text
            touched_files.add(edit.relpath)

    if not args.dry_run:
        for relpath, text in by_file.items():
            if relpath in touched_files:
                (src_dir / relpath).write_text(text, encoding="utf-8")

    if failures:
        print("\nSTOPPING: the following expected compiler-flag literals were NOT found.", file=sys.stderr)
        print("This means upstream Thorium's build/config files have changed shape since", file=sys.stderr)
        print("this patch set was authored. Re-inspect the real source (see docs/ARCHITECTURE.md",
              file=sys.stderr)
        print("'How the zen5 patches were derived') and update scripts/apply_zen5_patches.py by hand", file=sys.stderr)
        print("-- do NOT guess a replacement.\n", file=sys.stderr)
        for relpath, marker in failures:
            print(f"  - {relpath}: marker not found: {marker}", file=sys.stderr)
        sys.exit(3)

    if args.capture_diffs and touched_files and not args.dry_run:
        capture_diffs(src_dir, sorted(touched_files), Path(args.patches_dir) if args.patches_dir else None)

    print(f"\nDone. {len(touched_files)} file(s) modified: {sorted(touched_files) or '(none -- already applied)'}")
    sys.exit(0)


def capture_diffs(src_dir: Path, relpaths: list[str], patches_dir: Path | None):
    patches_dir = patches_dir or (src_dir.parent / "patches" / "zen5")
    patches_dir.mkdir(parents=True, exist_ok=True)
    manifest = ["# Zen5 patches -- captured unified diffs\n",
                "# Regenerated automatically by apply_zen5_patches.py --capture-diffs\n\n"]
    for i, relpath in enumerate(relpaths, start=1):
        result = subprocess.run(
            ["git", "diff", "--", relpath], cwd=str(src_dir),
            capture_output=True, text=True, check=False,
        )
        safe_name = relpath.replace("/", "_").replace("\\", "_")
        out_file = patches_dir / f"{i:04d}-{safe_name}.patch"
        out_file.write_text(result.stdout, encoding="utf-8")
        manifest.append(f"{i:04d}-{safe_name}.patch  <-  {relpath}\n")
        print(f"Captured diff: {out_file}")
    (patches_dir / "MANIFEST.txt").write_text("".join(manifest), encoding="utf-8")


if __name__ == "__main__":
    main()
