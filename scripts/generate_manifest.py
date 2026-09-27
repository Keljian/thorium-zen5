#!/usr/bin/env python3
"""
Write build/build-manifest-<profile>.json: what exactly this build is.

chromium_tag is the version that orders releases. chrome_dll_sha256 is the
build's identity: two builds of one Chromium version (a flag or toolchain
change) differ there and nowhere else, and the deploy check compares it with
the installed chrome.dll.

Usage:
    python scripts/generate_manifest.py --repo-root C:\\thorium --profile zen5
"""
import argparse
import datetime
import hashlib
import json
import subprocess
from pathlib import Path


def sh(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def read_args_gn(path: Path) -> dict:
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


def sha256(path: Path):
    if not path.exists():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=r"C:\thorium")
    ap.add_argument("--profile", required=True)
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    src_dir = repo_root / "src"
    out_dir = src_dir / "out" / f"thorium-{args.profile}"
    tag_file = repo_root / "build" / "chromium-tag.txt"
    clang = src_dir / "third_party" / "llvm-build" / "Release+Asserts" / "bin" / "clang-cl.exe"

    manifest = {
        "manifest_schema_version": 2,
        "profile": args.profile,
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_revisions": {
            "chromium_src_commit": sh("git rev-parse HEAD", cwd=str(src_dir)),
            "chromium_src_commit_date": sh("git log -1 --format=%cI", cwd=str(src_dir)),
            "chromium_tag": tag_file.read_text().strip() if tag_file.exists() else None,
            "thorium_zen5_repo_commit": sh("git rev-parse HEAD", cwd=str(repo_root)),
        },
        "chrome_dll_sha256": sha256(out_dir / "chrome.dll"),
        "compiler": {
            "clang_version_string": sh(f'"{clang}" --version') if clang.exists() else None,
        },
        "gn_args": read_args_gn(out_dir / "args.gn"),
        "output_dir": str(out_dir),
    }

    out_path = repo_root / "build" / f"build-manifest-{args.profile}.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(manifest, indent=2))
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
