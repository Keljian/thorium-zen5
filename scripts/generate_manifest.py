#!/usr/bin/env python3
"""
generate_manifest.py -- writes build/build-manifest-<profile>.json, the
single source of truth for "what exactly was this build" per the project's
requirement to record: source revisions, compiler revision, GN args,
Windows SDK version, LLVM version, build timestamp, and git commit hashes.

Usage:
    python3 scripts/generate_manifest.py --repo-root C:\\thorium --profile zen5 \
        --out build/build-manifest-zen5.json
"""
import argparse
import datetime
import json
import subprocess
from pathlib import Path


def sh(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def read_args_gn(path: Path) -> dict:
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def get_clang_version(src_dir: Path) -> str | None:
    clang = src_dir / "third_party" / "llvm-build" / "Release+Asserts" / "bin" / "clang-cl.exe"
    if not clang.exists():
        return None
    return sh(f'"{clang}" --version')


def get_windows_sdk_version() -> str | None:
    # Chromium records the resolved SDK version in this generated file after `gn gen`.
    return None  # filled in by caller if out/<profile>/environment.x64 or similar exists; see build.ps1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=r"C:\thorium")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--windows-sdk-version", default=None,
                     help="Passed by build.ps1, which reads it from vswhere/registry.")
    ap.add_argument("--build-status", default="unknown",
                     choices=["success", "failed", "partial", "unknown"])
    ap.add_argument("--extra-json", default=None, help="path to a JSON file of extra fields to merge in")
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    src_dir = repo_root / "src"
    out_dir = src_dir / "out" / f"thorium-{args.profile}"
    thorium_meta_dir = repo_root / "upstream" / "Thorium"

    manifest = {
        "manifest_schema_version": 1,
        "profile": args.profile,
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "build_status": args.build_status,
        "source_revisions": {
            "chromium_src_commit": sh("git rev-parse HEAD", cwd=str(src_dir)),
            "chromium_src_commit_date": sh("git log -1 --format=%cI", cwd=str(src_dir)),
            "thorium_meta_repo_commit": sh("git rev-parse HEAD", cwd=str(thorium_meta_dir)),
            "thorium_zen5_repo_commit": sh("git rev-parse HEAD", cwd=str(repo_root)),
        },
        "compiler": {
            "clang_version_string": get_clang_version(src_dir),
        },
        "windows_sdk_version": args.windows_sdk_version,
        "gn_args": read_args_gn(out_dir / "args.gn"),
        "output_dir": str(out_dir),
    }

    if args.extra_json and Path(args.extra_json).exists():
        extra = json.loads(Path(args.extra_json).read_text())
        manifest.update(extra)

    out_path = Path(args.out) if args.out else repo_root / "build" / f"build-manifest-{args.profile}.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(manifest, indent=2))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
