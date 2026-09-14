# Benchmarks

See `benchmarks/README.md` for how to run them. This file records actual
results as they're produced -- it starts empty because no build has been
benchmarked yet. Append a dated section each time you run
`build.ps1 benchmark` for a profile you care to keep a record of, e.g.:

```markdown
## 2026-09-20 -- Chromium <commit>, Thorium <commit>

| Profile | Startup mean (s) | Speedometer 3.0 | AVX-512 instrs | ZMM instrs | Binary size (chrome.dll) |
|---|---|---|---|---|---|
| baseline | ... | ... | 0 | 0 | ... |
| generic-avx512 | ... | ... | ... | ... | ... |
| zen5 | ... | ... | ... | ... | ... |
```

Fill these from `build/benchmark-<profile>.json`,
`build/isa-report-<profile>.json`, and `build/compare-report.txt` -- never
hand-estimate a number for this table.
