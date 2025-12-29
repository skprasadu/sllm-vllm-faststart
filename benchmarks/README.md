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
| 2025-12-27T21:04:16Z | 4f3aa3b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 96740 | 108999 | 0.89 | 0.530 | 0.317 | drop_caches=1, note=H100 NVMe tuned store: threads=16 chunk=128MB, cold cache, ports=baseline:8001,faststart:8082, mem_pool=32GB | [json](results/coldstart_20251227_211503.json) |
| 2025-12-27T18:01:53Z | ae9310e | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 39824 | 50092 | 0.80 | 0.537 | 0.319 | drop_caches=1, note=H100 NVMe, cold cache, ports=baseline:8001,faststart:8082, mem_pool=16GB | [json](results/coldstart_20251227_180652.json) |
| 2025-12-27T15:59:49Z | b79a401 | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 32524 | 106107 | 0.31 | 0.540 | 0.315 | note=Azure H100, mem_pool=32GB, ports=baseline:8001,faststart:8082, mem_pool=32GB | [json](results/coldstart_20251227_160807.json) |
| 2025-12-27T15:48:17Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 95725 | 108040 | 0.89 | 0.537 | 0.319 | drop_caches=1, note=Azure H100, cold cache, mem_pool=32GB, ports=baseline:8001,faststart:8082, mem_pool=32GB | [json](results/coldstart_20251227_155904.json) |
| 2025-12-27T15:27:56Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 32288 | 106098 | 0.30 | 0.530 | 0.318 | note=Azure H100, mem_pool=32GB, ports=baseline:8001,faststart:8082, mem_pool=32GB | [json](results/coldstart_20251227_153515.json) |
| 2025-12-27T14:41:46Z | 04b668b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 32387 | 106121 | 0.31 | 0.531 | 0.318 | note=Azure H100, ubuntu 22.04, ports=baseline:8001,faststart:8082, mem_pool=16GB | [json](results/coldstart_20251227_144903.json) |
| 2025-12-26T18:36:28Z | 301a084 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 49579 | 54894 | 0.90 | 1.021 | 0.856 | drop_caches=1, note=Azure T4, ubuntu 22.04 | [json](results/coldstart_20251226_184217.json) |
| 2025-12-26T17:08:10Z | e9d1504 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 43019 | 50233 | 0.86 | 0.996 | 0.832 | note=Azure T4, ubuntu 22.04 | [json](results/coldstart_20251226_171323.json) |
<!-- BENCHMARKS:END -->

<!-- FASTRESTART:START -->
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline restart ready median (ms) | Faststart restart ready median (ms) | Restart speedup (x) | Baseline restart first completion median (s) | Faststart restart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| 2025-12-29T00:21:34Z | 8710be9 | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 31488 | 26207 | 1.20 | 0.537 | 0.313 | drop_caches=1, note=H100 NVMe tuned store: threads=16 chunk=128MB, pagecache dropped, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251229_002613.json) |
| 2025-12-28T15:03:20Z | 21d2e22 | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 31695 | 26288 | 1.21 | 0.538 | 0.312 | drop_caches=1, note=offline, drop caches (NVMe mounted), ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251228_150823.json) |
| 2025-12-27T20:55:33Z | 4f3aa3b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 89257 | 27420 | 3.26 | 0.550 | 0.313 | drop_caches=1, note=H100 NVMe tuned store: threads=16 chunk=128MB, pagecache dropped, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_210411.json) |
| 2025-12-27T20:49:54Z | 4f3aa3b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 29071 | 24141 | 1.20 | 0.529 | 0.311 | note=H100 NVMe tuned store: threads=16 chunk=128MB, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_205520.json) |
| 2025-12-27T17:56:53Z | ae9310e | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 32566 | 27476 | 1.19 | 0.528 | 0.315 | drop_caches=1, note=H100 NVMe, store warm, OS pagecache dropped, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_180143.json) |
| 2025-12-27T15:41:07Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 26293 | 24159 | 1.09 | 0.515 | 0.313 | note=Azure H100, store sidecar, mem_pool=32GB, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_154611.json) |
| 2025-12-27T15:35:27Z | 3d88a0c | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 26323 | 24153 | 1.09 | 0.519 | 0.318 | note=Azure H100, store sidecar, mem_pool=32GB, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_154031.json) |
| 2025-12-27T14:49:17Z | 04b668b | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 26301 | 24160 | 1.09 | 0.552 | 0.314 | note=Azure H100, ubuntu 22.04, store sidecar, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_145423.json) |
| 2025-12-27T14:34:18Z | d92b0a7 | TCE-Lab-Linux-GPU | NVIDIA H100 NVL, 95830 MiB | meta-llama/Llama-3.1-8B-Instruct | 3 | 29423 | 24169 | 1.22 | 0.517 | 0.312 | note=Azure H100, ubuntu 22.04, store sidecar, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251227_144104.json) |
| 2025-12-26T21:22:52Z | 56c2e47 | TCE-serverless-v1 | Tesla T4, 15360 MiB | Qwen/Qwen3-0.6B | 3 | 36323 | 35553 | 1.02 | 1.004 | 0.832 | note=Azure T4, ubuntu 22.04, store sidecar, ports=baseline:8001,faststart:8082 | [json](results/fastrestart_20251226_212833.json) |
<!-- FASTRESTART:END -->
