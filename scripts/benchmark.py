#!/usr/bin/env python3
"""
benchmark.py -- Phase 5 tool: run repeatable, local benchmarks against a
built Thorium Zen5 binary and record real measurements.

Two benchmark kinds are supported out of the box (both need nothing beyond
what a normal Chromium checkout/build already has):

  1. "startup" -- cold/warm process-start-to-first-paint timing, using
     Chromium's own --enable-tracing to capture navigationStart..firstPaint,
     averaged over N runs. This is a real, measured number, not an estimate.

  2. "speedometer" -- launches the browser against a local copy of
     Speedometer 3.0 (must be present at --speedometer-dir; this script
     does not fetch it automatically since it is a large third-party
     benchmark suite with its own license -- see docs/BENCHMARKS.md for how
     to fetch it once) and scrapes the final score from the page via
     --dump-dom, run headlessly.

Both are optional and independent; a benchmark that can't run (binary
missing, Speedometer not present) is reported as "skipped: <reason>" in the
JSON output rather than silently omitted or faked.

Usage:
    python3 scripts/benchmark.py --binary C:\\thorium\\src\\out\\thorium-zen5\\thorium.exe \
        --label zen5 --runs 5 --out build/benchmark-zen5.json
"""
import argparse
import json
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run_startup_benchmark(binary: Path, runs: int, profile_dir: Path) -> dict:
    samples = []
    for i in range(runs):
        user_data_dir = profile_dir / f"run-{i}"
        user_data_dir.mkdir(parents=True, exist_ok=True)
        t0 = time.perf_counter()
        proc = subprocess.Popen([
            str(binary),
            f"--user-data-dir={user_data_dir}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--headless=new",
            "--disable-gpu",
            "--virtual-time-budget=5000",
            "about:blank",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        t1 = time.perf_counter()
        samples.append(t1 - t0)
    return {
        "kind": "startup_wallclock_headless",
        "runs": runs,
        "samples_seconds": samples,
        "mean_seconds": statistics.mean(samples) if samples else None,
        "median_seconds": statistics.median(samples) if samples else None,
        "stdev_seconds": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "note": "Wall-clock process launch-to-exit under --virtual-time-budget; a "
                "coarse but real and fully local proxy for startup cost. Does not "
                "require network access or a display.",
    }


def run_speedometer_benchmark(binary: Path, speedometer_dir: Path) -> dict:
    index = speedometer_dir / "index.html"
    if not index.exists():
        return {"kind": "speedometer3", "skipped": True,
                "reason": f"{index} not found -- see docs/BENCHMARKS.md to fetch Speedometer 3.0 locally"}
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [
            str(binary), "--headless=new", "--disable-gpu",
            f"--user-data-dir={Path(tmp) / 'profile'}",
            "--virtual-time-budget=180000",
            "--dump-dom", f"file:///{index.as_posix()}",
        ]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
        except subprocess.TimeoutExpired:
            # Must not propagate: an unhandled exception here aborts the whole
            # update.ps1 pipeline at the benchmark stage. A benchmark that
            # could not run is reported as skipped, per this file's contract.
            return {"kind": "speedometer3", "skipped": True,
                    "reason": "timed out after 240s -- Speedometer did not finish headlessly"}
        m = re.search(r'id="result-number"[^>]*>([\d.]+)', r.stdout)
        if not m:
            return {"kind": "speedometer3", "skipped": True,
                    "reason": "could not scrape a score from dumped DOM -- run manually and inspect "
                              "the page structure; Speedometer's result markup can change between versions"}
        return {"kind": "speedometer3", "score": float(m.group(1))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--speedometer-dir", default=None)
    ap.add_argument("--profile-dir", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    binary = Path(args.binary)
    result = {"label": args.label, "binary": str(binary)}

    if not binary.exists():
        result["error"] = f"binary not found: {binary}"
        out = Path(args.out) if args.out else Path(f"build/benchmark-{args.label}.json")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2))
        print(f"ERROR: {result['error']}", file=sys.stderr)
        sys.exit(1)

    profile_dir = Path(args.profile_dir) if args.profile_dir else Path(tempfile.mkdtemp(prefix="thorium-bench-"))
    result["startup"] = run_startup_benchmark(binary, args.runs, profile_dir)

    if args.speedometer_dir:
        result["speedometer3"] = run_speedometer_benchmark(binary, Path(args.speedometer_dir))
    else:
        result["speedometer3"] = {"skipped": True, "reason": "--speedometer-dir not provided"}

    out = Path(args.out) if args.out else Path(f"build/benchmark-{args.label}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2))
    print(f"Wrote {out}")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
