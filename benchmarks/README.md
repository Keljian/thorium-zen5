# benchmarks/

`build.ps1 benchmark -Profile <profile>` calls `scripts/benchmark.py`, which
runs entirely local, no-network-required benchmarks by default:

- **startup**: wall-clock time to launch the built browser headless with a
  bounded virtual-time budget, averaged over 5 runs. Always runs.

## Optional: Speedometer 3.0

For a real web-application-responsiveness score, download
[Speedometer 3.0](https://browserbench.org/Speedometer3.0/) locally (it's a
static site with its own license -- this project does not vendor it):

```powershell
git clone https://github.com/WebKit/Speedometer.git C:\thorium\benchmarks\speedometer
```

Then pass `-SpeedometerDir C:\thorium\benchmarks\speedometer\.build` (or
wherever `index.html` ends up after Speedometer's own build step -- see its
README) to `build.ps1 benchmark`. If the directory or `index.html` isn't
found, `scripts/benchmark.py` records `"skipped"` with the reason rather
than fabricating a score.

## Comparing profiles

After benchmarking two or more profiles, run:

```powershell
python3 scripts\compare_builds.py --repo-root C:\thorium --profiles baseline zen5 generic-avx512
```

which reads each profile's `build/benchmark-<profile>.json`,
`build/isa-report-<profile>.json`, and `out/thorium-<profile>/args.gn`, and
writes `build/compare-report.json` / `.txt`. It never estimates a number it
didn't read from one of those files.
