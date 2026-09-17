#!/usr/bin/env python3
"""
run_bench_suite.py -- alternating baseline/zen5 Speedometer suite + statistics.

Runs N pairs. Within each pair both builds run back to back, and the ORDER
FLIPS every pair (baseline-first, zen5-first, baseline-first, ...). That
cancels monotonic drift -- thermal soak, background Windows work, GPU clock
settling -- which otherwise lands entirely on whichever build always goes
second.

Each run is a separate process with its own profile directory and its own
debugging port, and speedometer_cdp.py records the SHA256 of the binary it
actually drove. A run whose provenance cannot be confirmed is reported, not
silently averaged in.

Statistics are Welch's t-test (unequal variance), with the p-value from a
regularized incomplete beta -- not a normal approximation, because n is
small. Nothing here estimates a number it did not measure.
"""

import argparse
import json
import math
import statistics
import subprocess
import sys
import time
from pathlib import Path


# ---- Welch's t-test ------------------------------------------------------
def _betacf(a, b, x, itmax=200, eps=3e-16):
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    if abs(d) < 1e-300:
        d = 1e-300
    d = 1.0 / d
    h = d
    for m in range(1, itmax + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < 1e-300:
            d = 1e-300
        c = 1.0 + aa / c
        if abs(c) < 1e-300:
            c = 1e-300
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < 1e-300:
            d = 1e-300
        c = 1.0 + aa / c
        if abs(c) < 1e-300:
            c = 1e-300
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1.0) < eps:
            break
    return h


def betainc(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lb = (math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
          + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1.0) / (a + b + 2.0):
        return math.exp(lb) * _betacf(a, b, x) / a
    return 1.0 - math.exp(lb) * _betacf(b, a, 1.0 - x) / b


def welch(xs, ys):
    """Returns (mean_x, mean_y, t, df, two_sided_p)."""
    nx, ny = len(xs), len(ys)
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    if nx < 2 or ny < 2:
        return mx, my, float("nan"), float("nan"), float("nan")
    vx, vy = statistics.variance(xs), statistics.variance(ys)
    sx, sy = vx / nx, vy / ny
    denom = math.sqrt(sx + sy)
    if denom == 0:
        return mx, my, float("nan"), float("nan"), float("nan")
    t = (my - mx) / denom
    df_num = (sx + sy) ** 2
    df_den = (sx * sx) / (nx - 1) + (sy * sy) / (ny - 1)
    df = df_num / df_den if df_den else float("nan")
    p = betainc(df / 2.0, 0.5, df / (df + t * t)) if df == df else float("nan")
    return mx, my, t, df, p


# ---- suite ---------------------------------------------------------------
def run_one(py, driver, exe, label, port, url, out_json, timeout):
    cmd = [py, driver, "--exe", exe, "--label", label, "--port", str(port),
           "--url", url, "--out-json", out_json,
           "--profile-dir", str(Path(out_json).parent / f"prof-{label}-{port}")]
    print(f"  -> {label} (port {port})", flush=True)
    r = subprocess.run(cmd, timeout=timeout)
    try:
        return json.loads(Path(out_json).read_text(encoding="utf-8"))
    except Exception:
        return {"label": label, "ok": False, "error": f"no json (exit {r.returncode})"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=r"C:\thorium")
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--pairs", type=int, default=5)
    ap.add_argument("--url", default="https://browserbench.org/Speedometer3.1/")
    ap.add_argument("--settle", type=int, default=20,
                    help="seconds of idle between runs, to let clocks/thermals settle")
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    root = Path(args.repo_root)
    driver = str(root / "scripts" / "speedometer_cdp.py")
    builds = {
        "baseline": str(root / "src" / "out" / "thorium-baseline" / "chrome.exe"),
        "zen5": str(root / "src" / "out" / "thorium-zen5" / "chrome.exe"),
    }
    for k, v in builds.items():
        if not Path(v).exists():
            print(f"FATAL: no {k} binary at {v}", file=sys.stderr)
            return 2

    stamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = Path(args.out_dir) if args.out_dir else root / "build" / f"bench-{stamp}"
    outdir.mkdir(parents=True, exist_ok=True)

    runs = []
    port = 9310
    for i in range(args.pairs):
        order = ["baseline", "zen5"] if i % 2 == 0 else ["zen5", "baseline"]
        print(f"pair {i+1}/{args.pairs}: {order[0]} then {order[1]}", flush=True)
        for label in order:
            port += 1
            res = run_one(args.python, driver, builds[label], label, port,
                          args.url, str(outdir / f"run-{i+1}-{label}.json"), 1800)
            res["pair"] = i + 1
            runs.append(res)
            time.sleep(args.settle)

    ok = [r for r in runs if r.get("ok") and isinstance(r.get("score"), (int, float))]
    bad = [r for r in runs if r not in ok]

    base = [r["score"] for r in ok if r["label"] == "baseline"]
    zen = [r["score"] for r in ok if r["label"] == "zen5"]

    report = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "url": args.url,
        "pairs_requested": args.pairs,
        "runs": runs,
        "failed_runs": len(bad),
        "baseline_scores": base,
        "zen5_scores": zen,
    }

    if len(base) >= 2 and len(zen) >= 2:
        mb, mz, t, df, p = welch(base, zen)
        report["stats"] = {
            "baseline_mean": mb,
            "zen5_mean": mz,
            "baseline_stdev": statistics.stdev(base),
            "zen5_stdev": statistics.stdev(zen),
            "delta_pct": (mz - mb) / mb * 100.0,
            "welch_t": t,
            "welch_df": df,
            "p_two_sided": p,
            "significant_at_0.05": bool(p == p and p < 0.05),
        }

    # Provenance: every accepted run must have driven a distinct, identified binary.
    hashes = {}
    for r in ok:
        hashes.setdefault(r["label"], set()).add(r.get("exe_sha256"))
    report["exe_sha256_by_label"] = {k: sorted(v) for k, v in hashes.items()}
    report["distinct_binaries_confirmed"] = (
        len(hashes.get("baseline", set())) == 1
        and len(hashes.get("zen5", set())) == 1
        and hashes.get("baseline") != hashes.get("zen5")
    )

    jf = outdir / "speedometer-suite.json"
    jf.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("\n" + "=" * 62)
    print(f"runs ok: {len(ok)}   failed: {len(bad)}")
    if bad:
        for r in bad:
            print(f"  FAILED {r.get('label')}: {r.get('error')}")
    print(f"distinct binaries confirmed: {report['distinct_binaries_confirmed']}")
    if "stats" in report:
        s = report["stats"]
        print(f"baseline : {s['baseline_mean']:.2f} +/- {s['baseline_stdev']:.2f}  n={len(base)}")
        print(f"zen5     : {s['zen5_mean']:.2f} +/- {s['zen5_stdev']:.2f}  n={len(zen)}")
        print(f"delta    : {s['delta_pct']:+.2f}%   p={s['p_two_sided']:.4f} "
              f"(Welch t={s['welch_t']:.3f}, df={s['welch_df']:.1f})")
        print(f"significant at 0.05: {s['significant_at_0.05']}")
    else:
        print("not enough successful runs for statistics")
    print(f"\nwrote {jf}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
