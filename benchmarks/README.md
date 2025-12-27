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
| 2025-12-27T15:48:17Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 95725 | 108040 | 0.89 | 0.537 | 0.319 | drop_caches=1, note=Azure H100, cold cache, mem_pool=32GB, ports=baseline:8001,faststart:8082, mem_pool=32GB | [json](results/coldstart_20251227_155904.json) |
| 2025-12-27T15:27:56Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 32288 | 106098 | 0.30 | 0.530 | 0.318 | note=Azure H100, mem_pool=32GB, ports=baseline:8001,faststart:8082, mem_pool=32GB | [json](results/coldstart_20251227_153515.json) |
| 2025-12-27T14:41:46Z | 04b668b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 32387 | 106121 | 0.31 | 0.531 | 0.318 | note=Azure H100, ubuntu 22.04, ports=baseline:8001,faststart:8082, mem_pool=16GB | [json](results/coldstart_20251227_144903.json) |
| 2025-12-26T18:36:28Z | 301a084 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 49579 | 54894 | 0.90 | 1.021 | 0.856 | drop_caches=1, note=Azure T4, ubuntu 22.04 | [json](results/coldstart_20251226_184217.json) |
| 2025-12-26T17:08:10Z | e9d1504 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 43019 | 50233 | 0.86 | 0.996 | 0.832 | note=Azure T4, ubuntu 22.04 | [json](results/coldstart_20251226_171323.json) |
<!-- BENCHMARKS:END -->

<!-- FASTRESTART:START -->
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline restart ready median (ms) | Faststart restart ready median (ms) | Restart speedup (x) | Baseline restart first completion median (s) | Faststart restart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| 2025-12-27T15:41:07Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 26293 | 24159 | 1.09 | 0.515 | 0.313 | note=Azure H100, store sidecar, mem_pool=32GB, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_154611.json) |
| 2025-12-27T15:35:27Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 26323 | 24153 | 1.09 | 0.519 | 0.318 | note=Azure H100, store sidecar, mem_pool=32GB, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_154031.json) |
| 2025-12-27T14:49:17Z | 04b668b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 26301 | 24160 | 1.09 | 0.552 | 0.314 | note=Azure H100, ubuntu 22.04, store sidecar, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_145423.json) |
| 2025-12-27T14:34:18Z | d92b0a7 | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 29423 | 24169 | 1.22 | 0.517 | 0.312 | note=Azure H100, ubuntu 22.04, store sidecar, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_144104.json) |
| 2025-12-26T21:22:52Z | 56c2e47 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 36323 | 35553 | 1.02 | 1.004 | 0.832 | note=Azure T4, ubuntu 22.04, store sidecar, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251226_212833.json) |
<!-- FASTRESTART:END -->
