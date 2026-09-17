# Benchmarks

Results are recorded here as they are produced. Every number below is
measured -- read out of `build/benchmark-<profile>.json`,
`build/isa-report-<profile>.json`, or a Speedometer 3.1 JSON export. Never
hand-estimate a number for these tables.

See `benchmarks/README.md` for how to run them.

---

## 2026-09-16 -- baseline vs zen5, Speedometer 3.1

### What was compared

Both builds are Chromium `154.0.8037.17`, src commit
`62d2fcb41a84e4dcefd8c4da7dfa534e6c482854`, same clang
(`24.0.0git`/`75adca17`), same official-build args, same PGO profile
(`chrome-win64-8037-1788890328-...`). The only difference is the zen5 profile's
extra args:

```
use_znver5 = true
zen5_march = "znver5"
zen5_mtune = "znver5"
zen5_slp_max_reg_size = "256"
zen5_extra_target_ldflags = [ "-mllvm:-enable-tail-merge=false" ]
```

Note: this is the zen5 build from 2026-09-15. It does **not** include the
later LTO knobs now sitting in `gn/win_zen5_args.gn`
(`-mllvm:-import-instr-limit=100`, `/opt:lldlto=3`,
`zen5_lto_backend_march = false`). Those are unbuilt and unmeasured.

### Method

Six Speedometer 3.1 runs on the same machine (9950X), alternating
baseline / zen5 / baseline / zen5 / baseline / zen5, back to back over about
three minutes. Ten iterations per run, so 30 iteration scores per profile.

**Caveat on the method.** How the two browsers were launched was not
recorded. If both were started without an explicit `--user-data-dir`, the
process singleton described under "Launch isolation" below means the second
launch fed its command line to the browser already running and every run came
from the same binary. That would produce exactly the near-zero difference
seen here, so this result cannot distinguish "no codegen effect" from "same
binary twice". Re-run it with `scripts\Start-BenchBrowser.ps1` before
treating it as settled.

### Per-run scores

| # | Profile | Score | 95% CI | Geomean (ms) |
|---|---|---|---|---|
| 1 | baseline | 32.66 | ±2.45 | 31.018 |
| 2 | zen5     | 33.94 | ±2.87 | 29.983 |
| 3 | baseline | 34.14 | ±1.19 | 29.355 |
| 4 | zen5     | 34.10 | ±1.59 | 29.449 |
| 5 | baseline | 34.39 | ±1.43 | 29.174 |
| 6 | zen5     | 34.49 | ±1.49 | 29.094 |

Median of the three run scores: baseline 34.14, zen5 34.10.

### Pooled iterations

Iteration 0 of every run is a cold-start outlier (23.4 to 30.2 against a
33 to 36 steady state), so both views are given.

| Sample | Baseline | Zen5 | Delta | Welch t | p |
|---|---|---|---|---|---|
| all 10 iterations (n=30) | 33.73 (sd 2.52) | 34.18 (sd 2.82) | +1.32% | 0.65 | 0.52 |
| dropping iteration 0 (n=27) | 34.42 (sd 1.09) | 34.95 (sd 1.21) | +1.56% | 1.72 | 0.09 |

Iterations inside one run are not independent, so the pooled t-test flatters
the result; the honest run-level view is three pairs differing by +1.28,
-0.04 and +0.10.

### Result

**No measurable difference.** Zen5 is ~1.3-1.6% ahead on the mean and the
difference does not clear the noise floor. Per-run confidence intervals run
±1.2 to ±2.9, wider than the effect. Six runs is not enough power to resolve
1.5%; roughly 30 runs per profile would be needed, and even then the answer
would be "about 1.5%, maybe".

### Per-workload breakdown

Mean of the three runs per profile, negative = zen5 faster. Included for
completeness, not as evidence: single-workload deltas at n=3 are noisier than
the aggregate.

| Workload | baseline (ms) | zen5 (ms) | delta |
|---|---|---|---|
| TodoMVC-WebComponents | 20.74 | 18.74 | -9.65% |
| TodoMVC-Preact-Complex-DOM | 14.76 | 13.75 | -6.85% |
| Editor-CodeMirror | 20.37 | 19.47 | -4.43% |
| NewsSite-Next | 64.13 | 62.04 | -3.27% |
| Perf-Dashboard | 36.82 | 35.91 | -2.50% |
| Editor-TipTap | 50.60 | 49.50 | -2.16% |
| TodoMVC-jQuery | 116.35 | 114.04 | -1.99% |
| TodoMVC-Svelte-Complex-DOM | 10.29 | 10.13 | -1.56% |
| React-Stockcharts-SVG | 52.79 | 52.47 | -0.61% |
| TodoMVC-Angular-Complex-DOM | 26.39 | 26.27 | -0.46% |
| TodoMVC-Backbone | 17.84 | 17.78 | -0.30% |
| Charts-chartjs | 30.81 | 30.91 | +0.33% |
| NewsSite-Nuxt | 51.21 | 51.61 | +0.79% |
| TodoMVC-JavaScript-ES6-Webpack-Complex-DOM | 36.34 | 36.63 | +0.80% |
| TodoMVC-React-Redux | 26.46 | 26.72 | +0.99% |
| TodoMVC-JavaScript-ES5 | 32.90 | 33.22 | +0.99% |
| Charts-observable-plot | 42.69 | 43.41 | +1.70% |
| TodoMVC-Vue | 20.63 | 21.06 | +2.05% |
| TodoMVC-React-Complex-DOM | 24.97 | 25.70 | +2.93% |
| TodoMVC-Lit-Complex-DOM | 14.99 | 15.46 | +3.10% |

### Binary and ISA

| Metric | baseline | zen5 | delta |
|---|---|---|---|
| chrome.dll | 301,824,512 B | 309,050,880 B | +2.39% |
| instructions disassembled | 68,342,682 | 69,660,888 | +1.93% |
| ZMM (512-bit) instructions | 63,734 (0.093%) | 331,405 (0.476%) | +420% |
| YMM (256-bit) instructions | 234,552 | 399,555 | +70% |
| classified AVX-512-family | 69,364 | 679,382 | +879% |

This is the explanation for the null result. Even after `-march=znver5`,
compiler-generated 512-bit code is 0.48% of the binary by instruction count.
The baseline already ships 63,734 ZMM instructions from third-party libraries
that dispatch on CPUID at runtime (Highway, dav1d, libjpeg-turbo, Skia,
zlib) -- those paths are identical in both builds. Speedometer is
DOM/JS/layout-bound, and none of that is vectorisable, so a 0.4pp shift in
512-bit density has nothing to act on.

### Startup (wall-clock, headless, 5 runs, `--virtual-time-budget`)

| Profile | mean (s) | median (s) | sd (s) |
|---|---|---|---|
| baseline | 0.782 | 0.680 | 0.336 |
| zen5 | 0.733 | 0.531 | 0.457 |

Five runs with a first-run outlier in both (1.43s and 1.65s). Not a result.

---

## 2026-09-17 -- MotionMark 1.3.2, discarded, and why

Three runs were taken: one scoring 2935.64 (±2.01%) and two scoring 1305.84
(±31.57%) and 1342.51 (±35.48%). The gap is 2.2x. The two low runs both had
the Design subtest fail to converge (±322.49% and ±574.73%), which is a
broken measurement rather than a slow one.

These runs are not recorded as a result. Nothing about the binaries explains
a 2.2x gap, and the launch conditions were not controlled.

### Launch isolation

Both builds default to `%LOCALAPPDATA%\Chromium\User Data` when no
`--user-data-dir` is given. Chromium's process singleton is keyed on the user
data directory. Verified on this machine: with the installed browser running,
launching `src\out\thorium-baseline\chrome.exe` starts **zero** processes from
that path -- the command line is handed to the running browser, which opens
the window. A benchmark run set up that way measures one binary twice, and
the second window inherits whatever else that browser was already doing,
which is a plausible source of both the low scores and the Design
non-convergence.

`scripts\Start-BenchBrowser.ps1` exists to prevent this. It gives each
profile its own user data directory, refuses to launch while another
benchmark browser is running, fixes the window geometry (MotionMark scales
with drawing surface size), and fails loudly if no process starts from the
binary it was asked for.

### GPU configuration is identical

Checked directly, not inferred: both binaries were launched with
`--remote-debugging-port` and queried over CDP with `SystemInfo.getInfo`. Every
`auxAttributes` field matches exactly, as do the feature status list and the
driver bug workarounds.

| | both builds |
|---|---|
| adapter | NVIDIA GeForce RTX 4080, driver 32.0.16.1692 |
| GL_RENDERER | ANGLE (NVIDIA, RTX 4080 (0x00002704) Direct3D11 vs_5_0 ps_5_0) |
| backend | `(gl=egl-angle,angle=d3d11)`, Skia GaneshGL |
| 2d_canvas / rasterization / gpu_compositing | enabled |
| skia_graphite | disabled_off |
| Vulkan | not supported |
| driver bug workarounds | same 6 |

So "one build lost hardware canvas" is ruled out. Windows per-application GPU
preferences (`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`) hold no
entry for either binary either, so both take the system default.

### What a valid re-run looks like

Use `Start-BenchBrowser.ps1` for each profile, one at a time, same window
geometry, window in the foreground and unoccluded for the whole run, and
confirm the process count it reports is non-zero. Alternate at least three
runs per profile. MotionMark punishes any frame the compositor drops for
reasons unrelated to the binary, so an occluded or background window is not a
measurement.

---

### What this means for the build config

The three toolchain workarounds in the zen5 profile
(`-enable-tail-merge=false` for llvm#199290, `slp-max-reg-size=256` for the
ISel gap, `-mtune=znver5`) exist to make `-march=znver5` build and run
correctly. On this evidence they are buying roughly nothing on Speedometer,
at the cost of a 2.4% larger chrome.dll and three deviations from stock
toolchain behaviour that have to be re-verified on every Chromium roll.

Nothing here argues the zen5 profile is *worse*. It argues that the win, if
there is one, is below what six runs can see, and that it is not where
`-march` was expected to deliver it. Workloads that do hit vectorised code
(media decode, image decode, canvas) were not measured and are the place to
look next.
