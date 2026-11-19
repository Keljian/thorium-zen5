# Toolchain bugs hit by this project

Current state: no toolchain workaround is in force. Both (BUG-1's tail-merge
ldflag, BUG-3's SLP cap) were retired on 2026-11-19, when clang
llvmorg-24-init-17044-gc3223914 stopped needing them. Re-test after every
clang roll with `.\build.ps1 canary` (below).

## Re-testing after a clang roll

`.\build.ps1 canary` needs a configured `out\thorium-zen5` and does two
things:

1. **SLP probe**, seconds. Recompiles `SkPathRawShapes.cpp` with its real
   command line minus the ThinLTO flags, so the X86 backend runs in the
   compiler, once capped and once uncapped, and counts zmm lines in each
   object. `FIXED` means the uncapped compile succeeds and is still 512-bit.
2. **Link canary**, a few minutes. Builds `root_store_tool` in
   `out\thorium-zen5-canary` with four `args.gn` variants: as configured,
   without the tail-merge ldflag, without the SLP cap, without either. Each
   deletes the ThinLTO cache and the binary first, so every variant relinks
   with cold codegen. Failures are classified by the signatures below.

Results go to `build\toolchain-canary.json` and `build\logs\canary.log`. A
workaround that is not set makes its variant identical to the configured one,
reported as "same as as-configured". So with both retired, the canary checks
the shipped config; if that link fails with one of the signatures below, put
the matching workaround back (`gn/win_zen5_args.gn` says how) and re-run.
`root_store_tool` does not contain the Skia code, so a full chrome build that
links is the last word on the SLP cap.

| date | clang | SLP probe, zmm capped / uncapped | as configured | no tail-merge | no SLP cap | neither |
|---|---|---|---|---|---|---|
| 2026-11-19 | llvmorg-24-init-17044-gc3223914 | FIXED, 2 / 11 | PASS | PASS | PASS | PASS |

---

Toolchain the BUG-1 matrices were measured on:

| | |
|---|---|
| Chromium | 154.0.8037.17 |
| clang | 24.0.0git (`75adca17`, Chromium-bundled) |
| Host/target | Windows x64, AMD Ryzen 9 9950X (Zen 5) |
| Build config | `is_official_build=true`, `use_thin_lto=true`, `chrome_pgo_phase=2` |

---

## BUG-1: `-mtune=znver*` miscompiles under ThinLTO

**Status:** llvm/llvm-project#199290 (branch folding orphans
`SEH_BeginEpilogue`). Worked around first with `zen5_mtune = "generic"`,
then with `-mllvm:-enable-tail-merge=false` and `zen5_mtune = "znver5"`.
Gone on llvmorg-24-init-17044-gc3223914; the ldflag was retired on
2026-11-19. The tail-merge diagnosis is in `gn/win_zen5_args.gn`.

### Symptom

Two failure signatures, both emitted by the ThinLTO backend at link time:

```
lld-link: error: <unknown>:0: Missing .seh_endepilogue in ?GetVlogLevelHelper@logging@@YAHPEBD_K@Z
lld-link: error: <unknown>:0: Missing .seh_endepilogue in ?Equals@BucketRanges@base@@QEBA_NPEBV12@@Z
```

and ~20 undefined symbols, all originating in `base/logging.cc` and its
perfetto trace-event companions, referenced from whole-program-devirtualization
branch funnels:

```
lld-link: error: undefined symbol: public: virtual void * __cdecl
    logging::LogMessage::`vector deleting dtor'(unsigned int)
>>> referenced by ./root_store_tool.exe.lto.obj:(__typeid_?AVLogMessage@logging@@_0_branch_funnel)
```

Which of the two appears varies with the link target and the exact flags. They
are **independent faults**, not cause and effect: disabling Windows unwind v2
removes the `.seh_endepilogue` errors and leaves all 20 undefined symbols in
place.

### Root cause

The AMD Zen **scheduling model** (`-mtune=znver4` / `-mtune=znver5`), not the
instruction set.

Isolated by holding the ISA constant and varying only `-mtune`. Each cell is a
full build of `net/tools/root_store_tool` (~2,500 steps, ~2 min):

| `-march` | `-mtune` | result |
|---|---|---|
| `skylake-avx512` | `skylake-avx512` | pass |
| `skylake-avx512` | **`znver4`** | **fail** |
| `znver4`, all AVX-512 extensions disabled via `-mno-*` | **`znver4`** | **fail** |
| `znver4` | `skylake-avx512` | pass |
| `znver5` | `skylake-avx512` | pass |
| `znver4` | `generic` | pass |
| `znver5` | `generic` | pass |

Every failure carries AMD scheduling; no passing configuration does. Row 3 is
the decisive one: it keeps `-mtune=znver4` while switching off the entire
AVX-512 extension set (VNNI, VBMI, VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI,
VAES, VPCLMULQDQ) and still fails. `znver4` and `znver5` behave identically.

The bug needs ThinLTO. Compiling `bucket_ranges.cc` standalone (no `-flto`)
succeeds under `znver4`, `znver5`, `skylake-avx512` and stock alike — it only
appears once cross-module inlining is involved.

### Why the workaround is `generic` and not an Intel `-mtune`

`-mtune=skylake-avx512` also builds cleanly, and is the wrong choice.
`prefer-256-bit` is a **tuning** feature in LLVM, so an Intel `-mtune`
silently suppresses all 512-bit vectorization. Counting vector registers in the
emitted assembly for a vectorizable FMA loop:

| `-march` / `-mtune` | zmm | ymm |
|---|---|---|
| `znver5` / `znver5` *(intended; does not build)* | 72 | 18 |
| `znver5` / **`generic`** *(shipped)* | **72** | **18** |
| `znver5` / `skylake-avx512` | **0** | 72 |
| `skylake-avx512` / `skylake-avx512` | 0 | 72 |
| stock, no `-march` | 0 | 0 |

`generic` reproduces the intended znver5 codegen exactly. An Intel `-mtune`
would have produced a green build that quietly discarded the entire point of
the project — the failure mode this table exists to prevent.

### Cost

Zen 5 instruction **scheduling** only. The full ISA, 512-bit vectorization,
PGO and ThinLTO are unaffected. On an 8-wide out-of-order core with a ~448-entry
reorder buffer, static scheduling is a second-order effect; PGO (which governs
inlining and block layout) is applied identically either way. This has not been
benchmarked here — `scripts/run_bench_suite.py` is the way to quantify it.

### Recovery

Done: `zen5_mtune = "znver5"` ships, first with the tail-merge ldflag and,
since 2026-11-19, without it. The failure is a hard link error, so a clang
that brings it back is obvious at once. `verify-source.ps1` asserts
`zen5_mtune`, and that the ldflag is on the chrome.dll link exactly when
`args.gn` asks for it.

---

## BUG-3: 512-bit SLP vectorization aborts X86 instruction selection

**Status:** gone on llvmorg-24-init-17044-gc3223914; `zen5_slp_max_reg_size`
went back to `""` on 2026-11-19.

```
LLVM ERROR: Cannot select: v4i64 = zero_extend_vector_inreg
In function: SkPathRawShapes::RRect::RRect(...)
```

Not AMD-specific: any 512-bit target hit it. Narrowed to the SLP vectorizer
(`-fno-slp-vectorize` fixed it, `-fno-vectorize` did not) and worked around
with `-mllvm:-slp-max-reg-size=256`, as an ldflag because under ThinLTO the
vectorizers run in the backend. Full notes in `gn/win_zen5_args.gn`.

---

## BUG-2 (not a bug): Windows unwind v2

`/clang:-fwinx64-eh-unwindv2=disabled` suppresses the `.seh_endepilogue` half of
BUG-1 and was briefly the intended fix. **It is not needed** — with
`zen5_mtune = "generic"` the build is clean at clang's default unwind-v2
setting. Verified: the same canary target builds `exit=0` with
`zen5_winunwindv2` set to `""` and to `"disabled"`.

The knob is retained (default `""`) for diagnosing this class of failure only.
Leaving unwind v2 at its default avoids switching off a Windows feature
unnecessarily — it is unwind *metadata* rather than an exploit mitigation, but
it is adjacent to CET shadow-stack unwinding and this build links `/CETCOMPAT`.

The link-time overrides (`-mllvm:-x86-wineh-unwindv2-force-mode`) **cannot**
substitute for the compile-time flag: mode `0` is the "no override" sentinel so
`disabled` is unreachable, and mode `2` (`required`) merely fails differently.
Raising `-x86-wineh-unwindv2-instruction-count-threshold` and
`-unwind-codes-threshold` to 1,000,000 changes nothing, ruling out chained
unwind-info splitting.

---

## Methodology note: the ThinLTO cache invalidates `-mllvm` experiments

**`-mllvm` flags are not part of LLVM's ThinLTO cache key.** Changing one and
relinking silently reuses cached codegen and "reproduces" the previous result in
about 3 seconds.

This corrupted two earlier conclusions in this project before it was noticed:

* *"`-march=znver5` miscompiles, use `znver4`"* — wrong. `znver4` fails
  identically; the original evidence came from one small link target that did
  not contain the triggering code.
* *"the ThinLTO backend flag `-mllvm:-march` is required"* — wrong. Relinking
  with it removed, against a **cold** cache, reproduces the failure identically.
  It was never what fixed anything.

Every measurement in this document used a fresh per-variant cache directory
(`/lldltocache:ltocache_<variant>`). Any future `-mllvm` experiment must do the
same, or it is measuring the cache. `build.ps1 canary` deletes the cache before
each variant, and `build.ps1 configure` clears `thinlto-cache` whenever
`args.gn` changes.

---

## Open question: is `zen5_lto_backend_march` doing anything?

`ldflags += [ "-mllvm:-march=$zen5_march" ]` is currently on
(`zen5_lto_backend_march = true`), inherited from Thorium's AVX-512 flavour.
Its necessity is **unproven** — see above. Note also that in LLVM's
`CommandFlags`, `-march` selects the *target architecture* and `-mcpu` selects
the CPU model, so the spelling may simply be inert.

Settle it by measurement, not argument: build with it on and off and compare
`scripts/analyze_isa.py` output on the finished `chrome.exe`. Do not reason
about it.
