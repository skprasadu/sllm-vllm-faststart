# Benchmarks

This folder contains repeatable cold-start benchmarks comparing:

- **baseline**: vLLM loading directly from HuggingFace cache
- **faststart**: vLLM loading from ServerlessLLM Store format (`--load-format serverless_llm`)

Run:
```bash
./benchmarks/run_coldstart_bench.sh --runs 3
```

<!-- BENCHMARKS:START -->
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline ready median (ms) | Faststart ready median (ms) | Ready speedup (x) | Baseline first completion median (s) | Faststart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| 2025-12-26T18:36:28Z | 301a084 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 49579 | 54894 | 0.90 | 1.021 | 0.856 | drop_caches=1, note=Azure T4, ubuntu 22.04 | [json](results/coldstart_20251226_184217.json) |
| 2025-12-26T17:08:10Z | e9d1504 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 43019 | 50233 | 0.86 | 0.996 | 0.832 | note=Azure T4, ubuntu 22.04 | [json](results/coldstart_20251226_171323.json) |
<!-- BENCHMARKS:END -->

<!-- FASTRESTART:START -->

<!-- FASTRESTART:END -->
