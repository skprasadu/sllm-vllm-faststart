# Benchmarks

This folder contains repeatable cold-start benchmarks comparing:

- **baseline**: vLLM loading directly from HuggingFace cache
- **faststart**: vLLM loading from ServerlessLLM Store format (`--load-format serverless_llm`)

Run:
```bash
./benchmarks/run_coldstart_bench.sh --runs 3