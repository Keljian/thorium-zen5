#!/usr/bin/env python3
"""
compare_builds.py -- Phase 6 tool: compare two or more completed builds
(baseline / zen5 / generic-avx512) on binary size, GN args, and ISA report
contents. Produces build/compare-report.json and a human-readable table.

This tool never invents numbers: every field it reports comes from an
actual file it read (args.gn, isa-report.json, build-manifest.json, or the
binary's own size on disk). If a comparison input is missing for a given
profile, that profile's row shows null/"missing" rather than being silently
skipped or estimated -- per the project's "do not claim performance
improvements without measurement" requirement.

Usage:
    python3 scripts/compare_builds.py --repo-root C:\\thorium \
        --profiles baseline zen5 generic-avx512 \
        --out-json build/compare-report.json --out-txt build/compare-report.txt
"""
import argparse
import json
from pathlib import Path


def read_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def read_args_gn(path: Path) -> dict:
    if not path.exists():
        return {}
    args = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            args[k.strip()] = v.strip()
    return args


def profile_dir(repo_root: Path, profile: str) -> Path:
    return repo_root / "src" / "out" / f"thorium-{profile}"


def binary_size(out_dir: Path) -> dict:
    sizes = {}
    for name in ("chrome.dll", "chrome.exe", "thorium.exe", "chrome_child.dll"):
        p = out_dir / name
        if p.exists():
            sizes[name] = p.stat().st_size
    return sizes


def collect(repo_root: Path, profile: str, build_root: Path) -> dict:
    out_dir = profile_dir(repo_root, profile)
    isa_report = read_json(build_root / f"isa-report-{profile}.json")
    manifest = read_json(build_root / f"build-manifest-{profile}.json")
    args_gn = read_args_gn(out_dir / "args.gn")
    return {
        "profile": profile,
        "out_dir": str(out_dir),
        "out_dir_exists": out_dir.exists(),
        "binary_sizes_bytes": binary_size(out_dir) if out_dir.exists() else {},
        "args_gn": args_gn if args_gn else None,
        "isa_report_avx512_total": (isa_report or {}).get("avx512_total"),
        "isa_report_zmm_instructions": (isa_report or {}).get("zmm_register_instructions"),
        "isa_report_bucket_counts": (isa_report or {}).get("bucket_counts"),
        "isa_report_available": isa_report is not None,
        "build_manifest_available": manifest is not None,
        "compiler_flags_summary": {
            "use_znver5": args_gn.get("use_znver5"),
            "use_generic_avx512": args_gn.get("use_generic_avx512"),
            "use_thin_lto": args_gn.get("use_thin_lto"),
            "chrome_pgo_phase": args_gn.get("chrome_pgo_phase"),
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=r"C:\thorium")
    ap.add_argument("--build-root", default=None, help="defaults to <repo-root>/build")
    ap.add_argument("--profiles", nargs="+", default=["baseline", "zen5", "generic-avx512"])
    ap.add_argument("--out-json", default=None)
    ap.add_argument("--out-txt", default=None)
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    build_root = Path(args.build_root) if args.build_root else repo_root / "build"
    out_json = Path(args.out_json) if args.out_json else build_root / "compare-report.json"
    out_txt = Path(args.out_txt) if args.out_txt else build_root / "compare-report.txt"

    rows = [collect(repo_root, p, build_root) for p in args.profiles]
    result = {"profiles": rows}
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(result, indent=2))

    with out_txt.open("w") as f:
        f.write("Build comparison\n" + "=" * 70 + "\n\n")
        for row in rows:
            f.write(f"Profile: {row['profile']}\n")
            if not row["out_dir_exists"]:
                f.write("  (not built -- run `build.ps1 build -Profile "
                        f"{row['profile']}` first)\n\n")
                continue
            f.write(f"  Output dir: {row['out_dir']}\n")
            for name, size in row["binary_sizes_bytes"].items():
                f.write(f"  {name}: {size:,} bytes\n")
            f.write(f"  Compiler flags: {row['compiler_flags_summary']}\n")
            if row["isa_report_available"]:
                f.write(f"  AVX-512-family instructions: {row['isa_report_avx512_total']}\n")
                f.write(f"  ZMM-register instructions:   {row['isa_report_zmm_instructions']}\n")
            else:
                f.write("  ISA report: not available (run scripts/analyze_isa.py for this profile)\n")
            f.write("\n")

        # Direct AVX-512-count delta table when both zen5 and generic-avx512 exist
        by_profile = {r["profile"]: r for r in rows}
        if "zen5" in by_profile and "generic-avx512" in by_profile:
            z = by_profile["zen5"]
            g = by_profile["generic-avx512"]
            if z["isa_report_available"] and g["isa_report_available"]:
                f.write("zen5 vs generic-avx512 AVX-512 instruction delta:\n")
                zc = z["isa_report_bucket_counts"] or {}
                gc = g["isa_report_bucket_counts"] or {}
                buckets = sorted(set(zc) | set(gc))
                for b in buckets:
                    f.write(f"  {b:22s} zen5={zc.get(b, 0):<8} generic-avx512={gc.get(b, 0):<8} "
                            f"delta={zc.get(b, 0) - gc.get(b, 0)}\n")

    print(f"Wrote {out_json} and {out_txt}")


if __name__ == "__main__":
    main()
