# Toolchain bugs hit by this project

Toolchain under test:

| | |
|---|---|
| Chromium | 154.0.8037.17 |
| clang | 24.0.0git (`75adca17`, Chromium-bundled) |
| Host/target | Windows x64, AMD Ryzen 9 9950X (Zen 5) |
| Build config | `is_official_build=true`, `use_thin_lto=true`, `chrome_pgo_phase=2` |

---

## BUG-1: `-mtune=znver*` miscompiles under ThinLTO

**Status:** open upstream (not yet filed). Worked around by `zen5_mtune = "generic"`.

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
benchmarked here — `build.ps1 benchmark` is the way to quantify it.

### Recovery

Set `zen5_mtune = "znver5"` in `gn/win_zen5_args.gn` and rebuild. The failure is
a hard link error, so a toolchain that has fixed it will be obvious immediately.
`verify-source.ps1` asserts the current value so it cannot drift unnoticed.

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
same, or it is measuring the cache.

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
