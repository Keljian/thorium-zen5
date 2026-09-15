# Zen 5 patches

What this project adds to a **stock Chromium** checkout to target AMD Zen 5
(Ryzen 9 9950X). Applied by `scripts/apply_zen5_patches.py`, which
`build.ps1 configure` runs for the `zen5` and `generic-avx512` profiles (the
`baseline` profile is left completely unpatched on purpose).

## Why there is anything to add at all

Stock Chromium does no x86 microarchitecture targeting. Verified directly
against Chromium **154.0.8037.17**: `build/config/compiler/BUILD.gn` is 3259
lines and contains exactly one `-march=` reference, `-march=$arm_arch`, for
ARM. Every x86 build is a generic x86-64 baseline.

So there is no upstream flag to flip and nothing to override. We add our own.

> Historical note: until 2026-09-14 this project overlaid Thorium's sources,
> and the patches here existed to *replace* Thorium's hardcoded
> `-mllvm:-march=skylake-avx512`. That overlay was dropped -- Thorium pinned
> Chromium 138 against a stable of 154, and all its release tags pointed at a
> single May 8 commit. See `docs/ARCHITECTURE.md`.

## The two edits

Both land in `build/config/compiler/BUILD.gn`.

**1. `declare_args()`**, inserted immediately before `config("compiler")`,
declaring `use_znver5`, `use_generic_avx512`, `zen5_march`, `zen5_mtune`,
`zen5_prefer_vector_width`, `zen5_slp_max_reg_size`, `zen5_winunwindv2`,
`zen5_lto_backend_march`, `zen5_extra_target_cflags` and
`zen5_extra_target_ldflags`. Every one defaults to the value that
reproduces stock behaviour, so a tree with the patch applied but no args set
builds byte-for-byte stock. That is what makes the `baseline` comparison
honest.

**2. A targeting block**, inserted inside `config("compiler")` right after
its flag-list initialisers (`cflags = []` ... `configs = []`). For x64
Windows clang target builds it emits `-march`/`-mtune`, plus whichever of
the toolchain workarounds are enabled.

The `is_a_target_toolchain` guard matters, with a caveat recorded in the
script itself: on a non-cross Windows x64 build the host and target
toolchains coincide, so host build tools receive these flags too. That is
acceptable here only because they are built and run on the same Zen 5
machine. Do not copy this to a cross build.

`-march=znver5` lets Clang's own CPU model select the complete instruction
set -- AVX512VNNI, VBMI, VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI, VAES,
VPCLMULQDQ -- plus Zen 5 scheduling. That is deliberately *not* a
hand-maintained feature list: a hand-maintained list goes stale and silently
under-targets.

## The ThinLTO backend flag is a no-op. Measured.

`zen5_lto_backend_march` defaults to **true** and emits
`-mllvm:-march=$zen5_march` as an ldflag. It does nothing, and the comment in
`apply_zen5_patches.py` calling this "UNVERIFIED" is now settled.

`-march` and `-mcpu` are different LLVM options. `--march=<string>` is
"Architecture to generate code for", from `CommandFlags.cpp`;
`--mcpu=<cpu-name>` is the one that names a processor. lld's LTO config takes
its CPU from `-mcpu`, and never reads `-march`. Probed directly against this
checkout's own linker, linking a trivial ThinLTO object:

```
lld-link t.obj ... -mllvm:-march=bogus123   -> exit 0, no diagnostic at all
lld-link t.obj ... -mllvm:-mcpu=bogus123    -> "'bogus123' is not a recognized
                                               processor for this target
                                               (ignoring processor)"
```

An invalid value for `-mcpu` is caught. An invalid value for `-march` is not
even looked at. The flag is inert.

This does not cost anything, because it was never what made the build target
Zen 5: Clang encodes `target-cpu` and `target-features` into the emitted
bitcode as per-function attributes, and the ThinLTO backend honours those
during codegen. That is why `build/isa-report-zen5.txt` shows 331,405 ZMM
instructions with the flag doing nothing.

**Action:** set `zen5_lto_backend_march = false`. It is dead weight, and
because `-mllvm` flags are not part of LLVM's ThinLTO cache key it is also a
standing invitation to mis-attribute a cached result.

If a genuine backend-wide CPU override is ever wanted, `-mllvm:-mcpu=znver5`
is the spelling that works. Do not add it casually: it would reapply Zen
scheduling across the whole LTO backend, which is the trigger for
llvm#199290 (see `docs/TOOLCHAIN-BUGS.md`), and the cflags already set
`tune-cpu` per function anyway.

## Robustness

`apply_zen5_patches.py` is anchored on exact text, not line numbers, and each
anchor must match **exactly once**. On any other count it prints the anchor,
writes nothing at all, and exits **3** -- which `build.ps1 configure` treats
as a hard stop, so no build is ever attempted from a half-patched tree. It is
idempotent: a marker string is checked first, so re-running is a no-op.

It also verifies brace balance is unchanged before writing.

Both anchors were re-checked against Chromium trunk (`origin/main` @
58199c7a, 2026-09-14, 3270 lines against 3260 at the pinned tag) and still
match exactly once.

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

## Known comment drift in the patcher

`apply_zen5_patches.py`'s `declare_args()` block still defaults
`zen5_mtune = "generic"` and carries a long comment saying znver4/znver5
"MUST NOT" be used. That was true before the `-enable-tail-merge=false`
workaround; the shipped `gn/win_zen5_args.gn` now sets
`zen5_mtune = "znver5"` and builds clean. The default and its comment should
be updated to match, which also changes the text inserted into the tree and
therefore the captured diff.