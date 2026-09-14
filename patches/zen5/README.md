# patches/zen5 -- Zen 5 (znver5) compiler-targeting patches

These patches are **not** hand-authored `.patch` files checked in ahead of
time. They are generated the first time you run

```powershell
.\build.ps1 configure -Profile zen5
```

against a real, synced source tree, by `scripts/apply_zen5_patches.py
--capture-diffs`. That script performs the edits (described below) against
the actual checked-out files and then runs `git diff` to capture the exact
result into this directory as `NNNN-<file>.patch`, plus a `MANIFEST.txt`.

Generating them this way -- rather than hand-typing unified diffs against
files we have only seen through a terminal -- avoids the single biggest
risk with maintaining Chromium patches: a line-offset or whitespace
mismatch that makes `git apply` silently fail or, worse, apply to the wrong
context. See `scripts/apply_zen5_patches.py`'s module docstring for exactly
how it locates each edit site (via exact, distinctive compiler-flag string
literals, not line numbers) and why that's robust to upstream reformatting.

Once generated, the `.patch` files in this directory are the durable,
reviewable record of what Zen5-profile changes were made -- commit them to
git normally. `update.ps1` re-runs `apply_zen5_patches.py` against each new
upstream sync; if a marker is no longer found (upstream changed the file's
shape), the script **stops with a non-zero exit code and does not guess**,
per the project's "detect patch conflicts, stop rather than silently
resolve incorrectly" requirement. When that happens, re-derive the new
marker/insertion point from the real updated file (see
`docs/ARCHITECTURE.md`) and update `scripts/apply_zen5_patches.py` by hand.

## What each edit does

| # | Upstream file | Purpose | Reason | Expected effect | Reversible? |
|---|---|---|---|---|---|
| 1 | `build/config/compiler_opt.gni` | Add a new `use_znver5` GN arg (default `false`) plus two sanity `assert()`s. | Thorium has no per-microarchitecture targeting arg at all -- only coarse SIMD-level flags (`use_avx2`, `use_avx512`, ...). We need a flag to opt into Zen5-specific codegen without disturbing any stock Thorium build (baseline, AVX2, generic-avx512 all keep working unmodified). | New arg is inert unless explicitly set `true` in `gn/win_zen5_args.gn`. | Fully reversible: delete the 6 added lines + trailing assert block, or simply never set `use_znver5 = true`. |
| 2 | `build/config/compiler/BUILD.gn` (Windows x64 branch) | Where stock Thorium would set `-mllvm:-march=haswell` (AVX2) or `-mllvm:-march=skylake-avx512` (AVX-512) as the ThinLTO backend's codegen/scheduling target, insert an `if (use_znver5) { ... } else` branch ahead of it that instead emits `/clang:-march=znver5 /clang:-mtune=znver5` (compile) and `-mllvm:-march=znver5` (ThinLTO backend). | This hardcoded `skylake-avx512` is the exact "generic AVX-512 treated as final target" problem: it caps codegen/scheduling to Skylake-X's model and instruction set, never touching Zen5-only ISA (VNNI, VBMI, VBMI2, BITALG, VPOPCNTDQ, IFMA, BF16, GFNI, VAES, VPCLMULQDQ). `-march=znver5` lets Clang select the complete, correct set itself. | Every TU compiled for the main `chrome`/`thorium` target (and everything ThinLTO-optimized at link time) is scheduled and vectorized for Zen 5 instead of Skylake-X. | Fully reversible: each inserted `if (use_znver5) {...} else` can be deleted, restoring the original unconditional `if (use_avx2)` / `if (use_avx512)` block verbatim. |
| 3 | `build/config/compiler/BUILD.gn` (Linux/Mac x64 branch) | Same transformation, mirrored for the non-Windows branch. | Not exercised by this Windows-only project, but keeps the source tree self-consistent (a future Linux zen5 profile would just need `use_znver5=true` in a Linux args.gn, no further patching). | No effect on the Windows build. | Same as above. |
| 4 | `build/config/win/BUILD.gn` (cflags block) | Insert the same `if (use_znver5) {...} else` ahead of the AVX-512 `cflags` array (this block previously had **no march= at all**, only individual `-mavx512*` feature flags). | Ensures the `cl.exe`-wrapper compile path (distinct from block above) also gets full Zen5 targeting, not just the ThinLTO linker backend. | Consistent codegen between the compile and link stages. | Fully reversible. |
| 5 | `build/config/win/BUILD.gn` (release ldflags block) | Same transformation for the second, separate `ldflags` block that sets the ThinLTO backend `-march` specifically for non-debug/non-component release builds. | This is the actual block that ships in `is_official_build=true` release configuration -- the one that matters for a real installer build. | Release build's ThinLTO backend targets Zen 5. | Fully reversible. |
| 6 | `v8/BUILD.gn` (Windows path) | Same transformation for V8's own, separately-declared AVX-512 `cflags`. | V8 (the JS engine) is compiled as mostly-separate GN targets with their own flag handling; without this edit V8's own object code would stay on the generic AVX-512 feature list even though the rest of the browser is Zen5-tuned. | V8 builtins/interpreter/Torque-generated code also compiled for Zen 5. | Fully reversible. |
| 7 | `v8/BUILD.gn` (non-Windows path) | Same transformation, mirrored. | Consistency; unused on Windows. | None on this project. | Fully reversible. |

## Regenerating after upstream changes

`update.ps1` calls:

```
python3 scripts/apply_zen5_patches.py --src-dir <src> --capture-diffs
```

If every marker is still found, new `.patch` files are written here
(overwriting the previous ones) and the pipeline continues. If any marker
is missing, the script exits 3 and `update.ps1` stops the whole pipeline
immediately -- no build, no test, no release is produced from a tree where
the Zen5 patches didn't actually apply.
