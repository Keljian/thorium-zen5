# Thorium Zen5

A personal Windows Chromium browser build, optimized for **AMD Ryzen 9
9950X (Zen 5) / AVX-512**, with an automated
source/update/build/test/package/installer pipeline. Built and run on a
single machine (`rohansdesktopry`); backward CPU compatibility is
explicitly not a goal.

The name is historical. Until 2026-09-14 this project overlaid Thorium's
source files onto a Chromium checkout. That overlay was dropped: Thorium
pinned Chromium 138 while stable was 154, and its release tags M144..M152
all pointed at a single May 8 commit, so there was no newer Thorium to
track. What this project needed from Thorium was the CPU targeting, and
that part is ours. **It now builds stock Chromium plus one local patch.**
See `docs/ARCHITECTURE.md`.

```powershell
.\build.ps1 all          # audit -> sync -> configure -> build -> test -> analyze -> benchmark -> package -> installer
.\update.ps1             # check for a newer Chromium stable and re-run the pipeline
```

## Start here

- **`docs/BUILD.md`** -- prerequisites and the full build walkthrough.
- **`docs/ARCHITECTURE.md`** -- repo layout, how the tree is patched, and
  what is deliberately left as runtime CPU dispatch.
- **`docs/UPDATES.md`** -- the automated update pipeline, the downgrade
  guard, and how patch conflicts are handled.
- **`docs/TOOLCHAIN-BUGS.md`** -- the three LLVM bugs this build works
  around, with the isolation matrices.
- **`docs/BENCHMARKS.md`** -- where measured results get recorded.
- **`build/audit.json`** -- machine-readable audit of the checkout: clang
  revision, whether it recognises `-march=znver5`, which files this
  project modifies, and a runtime-dispatch survey of the SIMD-heavy
  third-party libraries.
- **`patches/zen5/README.md`** -- what each edit does, why, and how to
  re-anchor it against a new Chromium revision.

## What this actually fixes

Stock Chromium does no x86 microarchitecture targeting at all. Verified
directly against 154.0.8037.17: `build/config/compiler/BUILD.gn` is 3259
lines and contains exactly one `-march=` reference, `-march=$arm_arch`,
for ARM. Every x86 build is a generic x86-64 baseline, so a 9950X runs
code scheduled for nothing in particular and touches none of its AVX-512.

There is therefore no upstream flag to flip and nothing to override. This
project adds its own: a `use_znver5` GN arg that emits `-march=znver5
-mtune=znver5` for the x64 Windows target compile, letting Clang's own
znver5 model select the complete instruction set -- AVX512VNNI, VBMI,
VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI, VAES, VPCLMULQDQ -- and the
Zen 5 scheduling model, rather than a hand-maintained feature list. The
arg defaults to false, so a patched tree with the arg unset builds
byte-for-byte stock. That is what makes the `baseline` profile an honest
comparison point.

## Status

Built, verified, measured, packaged and installed against Chromium
154.0.8037.17.

### The targeting is verified, not assumed

`verify-source.ps1 -Profile zen5` asserts that the targeting actually reached
the generated build files, rather than trusting `args.gn`. All five checks
pass:

| check | asserts |
|---|---|
| `cxx_march` / `cxx_mtune` | `-march=znver5 -mtune=znver5` on the C++ compile |
| `rust_cpu` | `-Ctarget-cpu=znver5` on the Rust compile |
| `tail_merge_workaround` | `-mllvm:-enable-tail-merge=false` on the chrome.dll link |
| `slp_cap_workaround` | `-mllvm:-slp-max-reg-size=256` on the chrome.dll link |

This section exists because every real failure on this project has been the
same shape: a flag that was declared but never applied, and therefore
invisible in a green build.

### Codegen, measured

From `build/isa-report-zen5.txt`, disassembling the shipped `chrome.dll`:

| | before Rust targeting | shipped | delta |
|---|---|---|---|
| total instructions | 69,660,888 | 69,523,617 | -137,271 (-0.20%) |
| ZMM (512-bit) | 331,405 | 361,105 | **+29,700 (+9.0%)** |
| YMM (256-bit) | 399,555 | 402,411 | +2,856 (+0.7%) |
| AVX-512 family | 679,382 | 714,183 | **+34,801 (+5.1%)** |

The delta column is the effect of exactly one change: `-Ctarget-cpu=znver5`
finally reaching rustc. GN `cflags` never reach rustc, so for this project's
entire history before that fix, 278 Rust rlibs -- font shaping and image
decode among them -- were compiled at the generic x86-64 baseline while
`args.gn` looked perfect. It bought 9% more 512-bit code in a *smaller*
binary.

The Zen-specific extensions (VNNI, VBMI, VBMI2, VPOPCNTDQ, IFMA, BITALG,
GFNI, VAES, VPCLMULQDQ) are all present, and none of them exist on
skylake-avx512, so the build really is targeting Zen 5 and not just
"some AVX-512".

### Binary size, which is what the workaround costs

Shipped artifacts from `out\thorium-zen5`:

| artifact | bytes | |
|---|---|---|
| `chrome.dll` | 308,667,904 | 294.4 MiB |
| `chrome.exe` | 4,424,704 | 4.2 MiB (launcher stub) |
| `mini_installer.exe` | 128,859,648 | 122.9 MiB |
| `setup.exe` | 6,247,936 | 6.0 MiB |

Against the `baseline` profile's `chrome.dll` (301,824,512 bytes), zen5 is
**+6,843,392 bytes, +2.27%**.

That delta is *not* attributable to the tail-merge workaround alone -- the
two profiles also differ by `-march`/`-mtune=znver5`,
`-mllvm:-import-instr-limit=100` and `/opt:lldlto=3`, and the first and third
of those inflate code size on their own. Disabling tail merging gives up a
code-size optimization, so it is a contributor, but isolating its share would
need a build that varies only that flag. Not measured, so not claimed.

### Releasing: what the pipeline gets wrong, and what now stops it

The upgrade pipeline could not complete a single release until 2026-09-18. Four
separate faults, none of which looked like what it was:

| symptom | actual cause |
|---|---|
| `A positional parameter cannot be found that accepts argument '-Profile'` | `Invoke-Stage` splatted an ARRAY, which passes every element positionally. Only `sync` (no named args) ever worked. |
| "already up to date" with a release-old browser | the check compared `chromium-tag.txt` (written by `sync`) against upstream, so a run that synced then failed marked itself done. Now keyed on the BUILT binary's version resource. |
| 70 "unexpected local modification" errors naming `option 'show_stats': 0` | `MIMALLOC_VERBOSE=1` at user scope; every `git` call printed allocator stats and the porcelain parser turned each line into a filename. |
| **9,032 tests failed** | the test launcher ran at **BelowNormal** priority and could not collect results from its children. |

That last one is the instructive one. `-Priority BelowNormal` exists so a
multi-hour build leaves the machine usable, and it is inherited by children.
Applied to the test launcher it breaks result collection outright. Measured on
one unchanged binary at the same `--test-launcher-jobs=14`, varying nothing but
the priority class:

| priority | result |
|---|---|
| Normal | 9,034 ran, **10** failed, 28 s, zero out-of-band errors |
| BelowNormal | 9,936 out-of-band errors, 9m26s, effectively serial on an **idle** machine |

So it was never CPU contention, and the exit code was identical in both cases --
which is why it read as "the build is broken" twice over.

Three things now keep this honest:

* `scripts\Run-Tests.ps1` reads per-test results from the launcher's JSON
  summary (via Python -- PowerShell 5.1's `ConvertFrom-Json` folds
  case-differing test names like `.../DE` and `.../de` together and throws),
  detects the out-of-band signature explicitly and reports it as a **harness
  fault** naming priority as the likely cause, and fails only on failures absent
  from `scripts\known-test-failures.txt`.
* That allowlist carries a reason and a retirement condition per entry, and the
  script reports entries that matched nothing so stale lines get pruned rather
  than accumulating until they hide something real.
* `update.ps1 -FromStage <stage>` resumes, because the pipeline being
  all-or-nothing is what turned one false test failure into a discarded
  two-and-a-quarter-hour build.

**The 10 remaining failures are not codegen.** Eight are
`ThreadPoolImplTest.IdentifiableStacks`, which asserts that frames named
`RunBlockShutdown` and friends appear in a live stack trace; it guards itself
with `stack.find("WorkerThread")`, which this build satisfies, so it proceeds
and then fails because `is_official_build` + ThinLTO + PGO has inlined those
diagnostic frames away. A generic official build fails it identically. The other
two are `PathServiceTest.Get`/`GetSystemTemp` -- path availability, **not
root-caused**, recorded rather than dismissed.

Independent of both verdicts: 58/58 pass with `--single-process-tests`, and the
installed binary returns
`MARKER center=255_0_0_255 corner_alpha=0 sum=59628256`, byte-identical to the
previous release -- so `roundRect` through `SkPathRawShapes::RRect` (the
ISel-bug function) and V8 arithmetic are both correct.

### Performance, honestly

**Speedometer 3.1, baseline vs zen5: +0.77%, p = 0.80, n=5 pairs. Not
significant.** Measured 2026-09-18 by `scripts/run_bench_suite.py`, ten
unattended runs with alternating order, each run recording the SHA256 of the
binary it drove. This replaces the 2026-09-16 result, which could not rule out
having measured the same binary twice.

The limit matters as much as the number: pooled SD was 1.97 points on a mean of
41.5, so **this test could only have detected an effect larger than about
8.4%**. It does not show the Zen 5 build is no faster; it shows any difference
is below what five pairs can resolve. Scores drifted 5.2 points (12.5%) across
the session on machine state alone -- twelve times the effect being sought.

**MotionMark: 2935.64 (+/-2.01%) zen5 vs 1305.84 (+/-31.57%) baseline.
Recorded, not believed.** A 2.2x on a graphics benchmark is not a plausible
consequence of instruction selection, and the baseline run's +/-31.57%
variance says that run was unstable rather than slow. It predates the
controlled harness and should be re-run under it.

So: the codegen change is real and verified; a user-visible speedup is not
established, and Speedometer is the wrong place to look for one. V8 emits its
own machine code at runtime and tops out at AVX2, so JITted JavaScript uses no
AVX-512 however `chrome.dll` was built -- the 512-bit code lives in Skia
raster, media and image decode, and the Rust crates. See `docs/BENCHMARKS.md`.

### Installed

A silent, user-level install of the shipped build sits at
`%LOCALAPPDATA%\Chromium\Application\154.0.8037.17`, registered as "Chromium"
in Add/Remove Programs. Its `chrome.dll` hashes identical to
`out\thorium-zen5\chrome.dll`. The existing profile under
`%LOCALAPPDATA%\Chromium\User Data` is adopted in place and was not modified.

Reinstall after any rebuild with:

```
out\thorium-zen5\mini_installer.exe --do-not-launch-chrome --verbose-logging
```

Note that on Windows `chrome.exe --version` does not print and exit -- it
ignores the flag and launches the browser. Read the version from the file's
version resource instead.

### Open items, stated rather than skipped

- **Two** toolchain workarounds are in force (tail-merge off, SLP capped at
  256 bits). The third, the `-mllvm:-march=` backend flag, was measured to be
  a no-op and is now off (`zen5_lto_backend_march = false`). See
  `docs/TOOLCHAIN-BUGS.md` and `patches/zen5/README.md`.
- The shipped binary carries two LTO knobs that are **unmeasured**:
  `-mllvm:-import-instr-limit=100` and `/opt:lldlto=3`. Plausible wins, not
  established ones.
- PGO uses Google's official generic win64 profile, not a Zen5-trained one.
  See `docs/BUILD.md` "About PGO".
- No Google API keys are baked in, by choice, so Sync and the Safe Browsing
  lookup service are inactive.
- `scripts/attribute_isa.py` (per-component, per-operation vector
  attribution) is committed but has never been run.
- The build volume is **NTFS-compressed at roughly 2.0:1** on this tree
  (250,033 files, 17.5 GB logical stored in 8.7 GB). Byte counts from
  `Get-ChildItem`/`.Length` are logical sizes, so actual disk usage -- and
  anything reclaimed by deleting build output -- is about half what they say.
  The binary sizes above are file sizes and are unaffected.
- `verify-source.ps1` now skips `git fsck` on the Chromium checkout by
  default; it cost 30-60+ minutes of solid CPU and starved the checks that
  actually catch regressions. Pass `-DeepFsck` when you specifically suspect
  checkout corruption.
