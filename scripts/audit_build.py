#!/usr/bin/env python3
"""
audit_build.py -- Phase 1 tool: inspect the actual synced Thorium/Chromium
source tree and compiler toolchain, and (re)produce build/audit.json.

This is deliberately NOT a static/hardcoded report. It greps the real,
checked-out source for the GN args and compiler-flag call sites that matter
(use_avx512, target_cpu, PGO, LTO, march=), classifies affected targets,
and records exactly what it found and what it could not determine.

Usage:
    python3 scripts/audit_build.py --repo-root C:\\thorium [--out build/audit.json]

Exit codes:
    0  audit completed (see build/audit.json "unresolved_questions" for gaps)
    1  source tree not found / not synced yet -- run build.ps1 sync first
    2  internal error while auditing
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Files in the STOCK Chromium checkout that this project's zen5 patches
# add CPU-targeting flags to. Stock Chromium has no microarchitecture arg of
# its own (and no compiler_opt.gni -- that was Thorium's), so these are the
# sites apply_zen5_patches.py edits. The grep pass below also searches the
# rest of the tree so a newly-introduced reference is not missed silently.
KNOWN_TARGETING_FILES = [
    "build/config/compiler/BUILD.gn",
    "build/config/win/BUILD.gn",
    "v8/BUILD.gn",
]

# Third-party components that are documented (upstream Chromium architecture)
# to use *runtime* CPU dispatch rather than build-time -march specialization.
# Verified per-checkout below by checking each path exists and, where
# feasible, grepping for a runtime dispatch signature (cpu detection call).
RUNTIME_DISPATCHED_CANDIDATES = {
    "third_party/highway": r"HWY_TARGETS|SupportedTargets",
    "third_party/dav1d": r"dav1d_get_cpu_flags|has_cpuid",
    "third_party/libjpeg_turbo": r"jsimd_can_|jpeg_simd_cpu_support",
    "third_party/skia": r"SkCpu|SkOpts::Init",
    "third_party/zlib": r"cpu_features|x86_cpu_enable",
}


def sh(cmd, cwd=None):
    # stdin=DEVNULL matters: some probes below invoke clang with `-` (read the
    # translation unit from stdin). Without an explicit DEVNULL the child
    # inherits our stdin and blocks forever waiting for EOF -- an unattended
    # pipeline hang, which is worse than a crash because nothing reports it.
    if cwd is not None and not os.path.isdir(cwd):
        return subprocess.CompletedProcess(cmd, 127, "", f"cwd does not exist: {cwd}")
    return subprocess.run(
        cmd, cwd=cwd, shell=True, check=False,
        capture_output=True, text=True, stdin=subprocess.DEVNULL,
    )


def find_src_dir(repo_root: Path) -> Path | None:
    for candidate in (repo_root / "src", repo_root / "chromium" / "src"):
        if (candidate / "build" / "config" / "BUILDCONFIG.gn").exists():
            return candidate
    return None


def get_chromium_version(src_dir: Path) -> str | None:
    version_file = src_dir / "chrome" / "VERSION"
    if not version_file.exists():
        return None
    parts = {}
    for line in version_file.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            parts[k.strip()] = v.strip()
    order = ["MAJOR", "MINOR", "BUILD", "PATCH"]
    if all(k in parts for k in order):
        return ".".join(parts[k] for k in order)
    return None


def get_clang_version(depot_tools_dir: Path, src_dir: Path) -> dict:
    clang_path = src_dir / "third_party" / "llvm-build" / "Release+Asserts" / "bin" / "clang-cl.exe"
    if not clang_path.exists():
        clang_path = src_dir / "third_party" / "llvm-build" / "Release+Asserts" / "bin" / "clang-cl"
    result = {"path": str(clang_path), "found": clang_path.exists(), "version_string": None,
              "supports_znver5": None}
    if clang_path.exists():
        r = sh(f'"{clang_path}" --version')
        result["version_string"] = (r.stdout or r.stderr).strip()
        # Compile an empty TU from NUL rather than stdin, so there is no way
        # for this probe to block on a reader.
        null_src = "NUL" if os.name == "nt" else "/dev/null"
        r2 = sh(f'"{clang_path}" --target=x86_64-pc-windows-msvc -march=znver5 -E -x c "{null_src}"')
        combined = ((r2.stdout or "") + (r2.stderr or ""))
        # The ONLY reliable signal is clang's own rejection message; the
        # previous expression here was `A and B or C`, which mixed precedence
        # and reported supports_znver5=True for unrelated failures.
        lowered = combined.lower()
        rejected = ("unknown target cpu" in lowered) or ("not a recognized processor" in lowered)
        result["supports_znver5"] = (r2.returncode == 0) and not rejected
        result["znver5_probe_returncode"] = r2.returncode
        result["znver5_probe_output"] = combined.strip()[-500:]
    return result


def grep_tree(src_dir: Path, pattern: str, include_globs, max_hits=500,
              max_files=None):
    """Grep files matching include_globs. Returns (hits, truncated).

    max_files bounds how many files are *examined* per call. Without it a
    signature that is simply absent causes a full walk of the subtree, reading
    every file: on the real checkout that made `build.ps1 audit` take 1h08m
    (measured on rohansdesktopry 2026-09-14), and audit runs twice per
    pipeline. third_party/skia alone is tens of thousands of files, and every
    read is also seen by the on-access virus scanner.

    Bounding it changes the third_party survey from exhaustive to a sample --
    so callers must report `truncated` rather than presenting a bounded "not
    found" as if it were a proven absence.
    """
    hits = []
    examined = 0
    truncated = False
    regex = re.compile(pattern)
    for glob in include_globs:
        for path in src_dir.glob(glob):
            if not path.is_file():
                continue
            if max_files is not None and examined >= max_files:
                truncated = True
                return hits, truncated
            examined += 1
            try:
                text = path.read_text(errors="ignore")
            except OSError:
                continue
            if regex.search(text):
                hits.append(str(path.relative_to(src_dir)))
            if len(hits) >= max_hits:
                return hits, truncated
    return hits, truncated


def audit(repo_root: Path, deep: bool = False) -> dict:
    src_dir = find_src_dir(repo_root)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()

    if src_dir is None:
        return {
            "audit_schema_version": 1,
            "generated_at": now,
            "status": "NO_SOURCE_TREE",
            "message": "No synced Chromium checkout found under 'src' or 'chromium/src'. "
                       "Run `.\\build.ps1 sync` first, then re-run the audit.",
        }

    chromium_version = get_chromium_version(src_dir)
    depot_tools_dir = repo_root / "depot_tools"
    clang_info = get_clang_version(depot_tools_dir, src_dir)

    # These globs are small and bounded by construction (build/config + v8),
    # so they stay exhaustive.
    avx512_files, _ = grep_tree(src_dir, r"use_generic_avx512",
                                ["build/config/**/*.gn", "build/config/**/*.gni", "v8/BUILD.gn"])
    znver5_files, _ = grep_tree(src_dir, r"use_znver5|znver5",
                                ["build/config/**/*.gn", "build/config/**/*.gni", "v8/BUILD.gn"])

    runtime_dispatch_findings = {}
    for rel, sig in RUNTIME_DISPATCHED_CANDIDATES.items():
        d = src_dir / rel
        if not d.exists():
            runtime_dispatch_findings[rel] = {"exists": False}
            continue
        scan_limit = None if deep else 400
        matched_files, truncated = grep_tree(
            src_dir, sig, [f"{rel}/**/*.cc", f"{rel}/**/*.c", f"{rel}/**/*.h"],
            max_hits=5, max_files=scan_limit)
        runtime_dispatch_findings[rel] = {
            "exists": True,
            "runtime_dispatch_signature_found_in": matched_files,
            # Only a positive result is conclusive under a bounded scan.
            "is_runtime_dispatched": True if matched_files else (False if not truncated else None),
            "scan_truncated": truncated,
            "scan_file_limit": scan_limit,
        }

    args_gn_path = src_dir / "out" / "thorium" / "args.gn"
    current_args = {}
    if args_gn_path.exists():
        for line in args_gn_path.read_text().splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                current_args[k.strip()] = v.strip()

    result = {
        "audit_schema_version": 1,
        "generated_at": now,
        "status": "OK",
        "chromium_version": chromium_version,
        "chromium_tag": (repo_root / "build" / "chromium-tag.txt").read_text().strip()
        if (repo_root / "build" / "chromium-tag.txt").exists() else None,
        "chromium_src_commit": sh("git rev-parse HEAD", cwd=str(src_dir)).stdout.strip() or None,
        "compiler": clang_info,
        "target_cpu": current_args.get("target_cpu"),
        "target_os": current_args.get("target_os"),
        "current_args_gn": current_args if current_args else None,
        "pgo_enabled": current_args.get("chrome_pgo_phase") not in (None, "0"),
        "pgo_data_path": current_args.get("pgo_data_path"),
        "lto_enabled": current_args.get("use_thin_lto") == "true",
        "avx512_enabled": current_args.get("use_generic_avx512") == "true",
        "znver5_enabled": current_args.get("use_znver5") == "true",
        "affected_targets": {
            "files_referencing_use_generic_avx512": avx512_files,
            "files_referencing_use_znver5": znver5_files,
        },
        "third_party_dispatch_survey": runtime_dispatch_findings,
        "modified_files": znver5_files,
        "unresolved_questions": [],
    }

    if clang_info.get("supports_znver5") is False:
        result["unresolved_questions"].append(
            "Bundled clang does NOT appear to recognize -march=znver5 (see compiler.znver5_probe_output). "
            "Upgrade the pinned clang via 'gclient sync' against a newer Chromium revision, or the zen5 "
            "build will fall back to a coarser -march (build.ps1 configure will fail loudly rather than "
            "silently downgrading)."
        )
    if not znver5_files:
        result["unresolved_questions"].append(
            "No references to use_znver5 found in the source tree -- the zen5 patches have not been "
            "applied yet. Run `.\\build.ps1 configure -Profile zen5` (which applies patches/zen5 first)."
        )
    for rel, info in runtime_dispatch_findings.items():
        if info.get("exists") and info.get("is_runtime_dispatched") is None:
            result["unresolved_questions"].append(
                f"{rel}: bounded scan (first {info.get('scan_file_limit')} files) found no runtime-dispatch "
                "signature. This is NOT proof of absence -- re-run `audit --deep` to scan exhaustively."
            )
            continue
        if info.get("exists") and info.get("is_runtime_dispatched") is False:
            result["unresolved_questions"].append(
                f"{rel} exists but no runtime-dispatch signature was found by this heuristic grep -- "
                "verify manually whether it needs a build-time zen5 specialization instead."
            )

    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=r"C:\thorium")
    ap.add_argument("--out", default=None, help="Defaults to <repo-root>/build/audit.json")
    ap.add_argument("--deep", action="store_true",
                    help="Scan third_party subtrees exhaustively. Much slower "
                         "(measured 1h08m on a real checkout) -- the default is a bounded sample.")
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    out_path = Path(args.out) if args.out else repo_root / "build" / "audit.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        result = audit(repo_root, deep=args.deep)
    except Exception as e:  # noqa: BLE001 - top-level tool, must report not crash silently
        print(f"AUDIT INTERNAL ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    if result.get("status") == "NO_SOURCE_TREE":
        # Deliberately do NOT write audit.json here. build/audit.json is a
        # tracked, hand-verified artifact; overwriting it with this 4-line
        # stub destroyed real content the first time `build.ps1 all` ran
        # before any sync (recovered via `git checkout -- build/audit.json`).
        # An audit that found nothing has nothing worth persisting.
        print("ERROR: " + result["message"], file=sys.stderr)
        print(f"(left {out_path} untouched)", file=sys.stderr)
        sys.exit(1)

    out_path.write_text(json.dumps(result, indent=2))
    print(f"Wrote {out_path}")

    if result["unresolved_questions"]:
        print("\nUnresolved questions:")
        for q in result["unresolved_questions"]:
            print(f"  - {q}")

    sys.exit(0)


if __name__ == "__main__":
    main()
