# Thorium Zen5

A personal Windows Chromium browser build, based on current Thorium
source, optimized for **AMD Ryzen 9 9950X (Zen 5) / AVX-512**, with an
automated source/update/build/test/package/installer pipeline. Built and
run on a single machine (`rohansdesktopry`); backward CPU compatibility is
explicitly not a goal.

```powershell
.\build.ps1 all          # audit -> sync -> configure -> build -> test -> analyze -> benchmark -> package -> installer
.\update.ps1             # check for upstream Thorium/Chromium updates and re-run the pipeline
```

## Start here

- **`docs/BUILD.md`** -- prerequisites and the full build walkthrough.
- **`docs/ARCHITECTURE.md`** -- repo layout, how the Zen5 patches were
  derived from the real Thorium source (with exact file/line evidence),
  and what's deliberately left as runtime CPU dispatch.
- **`docs/UPDATES.md`** -- the automated update pipeline and how patch
  conflicts / regressions are handled.
- **`docs/BENCHMARKS.md`** -- where measured results get recorded.
- **`build/audit.json`** -- machine-readable audit of exactly where
  Thorium currently controls AVX-512/target_cpu/PGO/LTO, and the ones this
  project changes for Zen5.
- **`patches/zen5/README.md`** -- what each Zen5 compiler-targeting patch
  does, why, and how to regenerate it against a new Thorium revision.

## What this actually fixes

Thorium's own `other/AVX512` flavor hardcodes `-mllvm:-march=skylake-avx512`
as the ThinLTO backend's codegen/scheduling target and only enables the
AVX-512 instructions common to *all* AVX-512 CPUs (F/CD/VL/BW/DQ) --
explicitly, per its own source comments, not tuned for any vendor. Zen 5
also has AVX512VNNI, VBMI, VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI,
VAES, and VPCLMULQDQ, none of which that build enables, and its scheduling
model is Skylake-X's, not Zen 5's. This project adds a new `use_znver5` GN
arg that -- everywhere Thorium special-cases AVX2/AVX-512 compiler and
linker flags -- instead emits `-march=znver5 -mtune=znver5`, letting
Clang's own target model pick the complete, correct instruction set and
scheduling, while leaving every stock Thorium build (baseline, AVX2,
generic AVX-512) completely unmodified unless that arg is set.

See `build/audit.json` and `docs/ARCHITECTURE.md` for the full inspection
trail this conclusion is based on.

## Status

Phase 1 (audit) and Phase 2 (Zen5 compiler profile + patches) are
implemented and tracked in this repo. Phases 3+ (a real build, ISA
measurement, benchmarks, installer, and a full update-cycle rehearsal)
require running this pipeline against a real, synced source tree on
`rohansdesktopry` -- see `docs/BUILD.md` to run it.
