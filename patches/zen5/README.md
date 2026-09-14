# Zen 5 patches

What this project adds to a **stock Chromium** checkout to target AMD Zen 5
(Ryzen 9 9950X). Applied by `scripts/apply_zen5_patches.py`, which
`build.ps1 configure` runs for the `zen5` and `generic-avx512` profiles (the
`baseline` profile is left completely unpatched on purpose).

## Why there is anything to add at all

Stock Chromium does no x86 microarchitecture targeting. Verified directly
against Chromium **154.0.8037.17**: `build/config/compiler/BUILD.gn` is 3259
lines and contains exactly one `-march=` reference — `-march=$arm_arch`, for
ARM. Every x86 build is a generic x86-64 baseline.

So there is no upstream flag to flip and nothing to override. We add our own.

> Historical note: until 2026-09-14 this project overlaid Thorium's sources,
> and the patches here existed to *replace* Thorium's hardcoded
> `-mllvm:-march=skylake-avx512`. That overlay was dropped — Thorium pinned
> Chromium 138 against a stable of 154, and all its release tags pointed at a
> single May 8 commit. See `docs/ARCHITECTURE.md`.

## The two edits

Both land in `build/config/compiler/BUILD.gn`.

**1. `declare_args()`**, inserted immediately before `config("compiler")`:

```gn
declare_args() {
  use_znver5 = false
  use_generic_avx512 = false
}
```

Both default to `false`, so a tree with the patch applied but neither arg set
builds byte-for-byte stock. That is what makes the `baseline` comparison
honest.

**2. A targeting block**, inserted inside `config("compiler")` right after its
flag-list initialisers (`cflags = []` … `configs = []`):

```gn
if (is_win && current_cpu == "x64" && is_clang && is_a_target_toolchain) {
  assert(!(use_znver5 && use_generic_avx512), ...)
  if (use_znver5) {
    cflags += [ "-march=znver5", "-mtune=znver5" ]
  } else if (use_generic_avx512) {
    cflags += [ "-march=skylake-avx512", "-mtune=skylake-avx512" ]
  }
}
```

The `is_a_target_toolchain` guard matters: without it the host toolchain
inherits the flags, and build tools that must run on the build machine (and
on other architectures) would be compiled for Zen 5.

`-march=znver5` lets Clang's own CPU model select the complete instruction
set — AVX512VNNI, VBMI, VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI, VAES,
VPCLMULQDQ — plus Zen 5 scheduling. That is deliberately *not* a
hand-maintained feature list: a hand-maintained list goes stale and silently
under-targets.

## Why no ThinLTO backend flag

We set compile flags only — no `-mllvm:-march=` / `-Wl,-mllvm,-march=`.

Clang encodes `target-cpu` and `target-features` into the emitted bitcode as
per-function attributes, and the ThinLTO backend honours them during codegen.
A backend override is therefore not obviously required, and which spelling
LLVM's LTO actually accepts (`-mcpu=` vs `-march=`) varies by version — a
wrong guess is silently ignored or rejected rather than loudly wrong.

This is left as a **measured** question, not an assumed one:
`scripts/analyze_isa.py` disassembles the built binary and counts real
AVX-512 instructions per ISA extension. If a `zen5` build shows no more
AVX-512 than `baseline`, that is the evidence to come back and add a backend
flag with — see `docs/BENCHMARKS.md`.

## Robustness

`apply_zen5_patches.py` is anchored on exact text, not line numbers, and each
anchor must match **exactly once**. On any other count it prints the anchor,
writes nothing at all, and exits **3** — which `build.ps1 configure` treats as
a hard stop, so no build is ever attempted from a half-patched tree. It is
idempotent: a marker string is checked first, so re-running is a no-op.

It also verifies brace balance is unchanged before writing.

## Regenerating after upstream changes

If Chromium restructures `config("compiler")`, the patcher will exit 3 and
name the anchor that no longer matches. To fix:

1. Open `src/build/config/compiler/BUILD.gn` at the current pinned tag.
2. Find the equivalent location (the `config("compiler")` declaration, and its
   `cflags`/`ldflags`/`configs` initialiser block).
3. Update `anchor1` / `anchor2` in `scripts/apply_zen5_patches.py`.
4. Re-run `build.ps1 configure -Profile zen5 -Force` and confirm the captured
   diff in this directory still shows only the two intended insertions.

The captured diff of the last successful application is committed here as
`build_config_compiler_BUILD.gn.diff`.
