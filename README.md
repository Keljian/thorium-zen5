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

Built, measured and packaged against Chromium 154.0.8037.17:

- `build/isa-report-zen5.txt` -- 69,660,888 instructions disassembled in
  chrome.dll, 331,405 of them using ZMM registers, 679,382 AVX-512-family
  total. The Zen-specific extensions (VNNI, VBMI, VBMI2, VPOPCNTDQ, IFMA,
  BITALG, GFNI, VAES, VPCLMULQDQ) are all present, and none of them exist
  on skylake-avx512, so the build really targets Zen 5.
- `build/build-manifest-zen5.json` -- the exact GN args, clang revision
  and Chromium commit the shipped binary came from.
- `releases/` -- packaged build plus its reports.

Open items, stated rather than skipped:

- **No `baseline` build exists**, so the performance value of the Zen 5
  targeting is unmeasured. 331,405 ZMM instructions is about 0.5% of the
  binary. `docs/BENCHMARKS.md` is still empty.
- Three toolchain workarounds are in force (tail-merge off, SLP capped at
  256 bits, and the `-mllvm:-march=` backend flag, which is measured to be
  a no-op). See `docs/TOOLCHAIN-BUGS.md` and `patches/zen5/README.md`.
- PGO uses Google's official generic win64 profile, not a Zen5-trained
  one. See `docs/BUILD.md` "About PGO".