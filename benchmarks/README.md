# Benchmarks

This folder contains repeatable cold-start benchmarks comparing:

- **baseline**: vLLM loading directly from HuggingFace cache
- **faststart**: vLLM loading from ServerlessLLM Store format (`--load-format serverless_llm`)

Run:
```bash
./benchmarks/run_coldstart_bench.sh --runs 3

<!-- BENCHMARKS:START -->
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline ready median (ms) | Faststart ready median (ms) | Ready speedup (x) | Baseline first completion median (s) | Faststart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
<!-- BENCHMARKS:END -->