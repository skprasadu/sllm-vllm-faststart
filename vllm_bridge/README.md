# Details# vLLM FastStart via ServerlessLLM Store (POC)

This folder is a **minimal, reproducible wedge**:
- run **baseline vLLM** (normal HF loading)
- run **faststart vLLM** (ServerlessLLM Store-backed loading)
- compare cold-start behavior & load times

We intentionally keep all customization localized under `vllm_bridge/`.

## Why this exists

ServerlessLLM Store provides a high-performance checkpoint format + loader.
ServerlessLLM documents a compatibility patch for vLLM (tested with vLLM 0.9.0.1) and a conversion script to save models into the Store format.

This POC uses:
- `vllm/vllm-openai:v0.9.0.1` (pinned)
- `serverless-llm-store==0.8.0` (pinned)
- upstream patch + `save_vllm_model.py` fetched from the ServerlessLLM repo tag `v0.8.0`

## Prerequisites

- Linux host with NVIDIA GPU + working `nvidia-smi`
- Docker + Docker Compose v2
- `nvidia-container-toolkit` installed (so containers can access the GPU)
- Persistent disk strongly recommended (so model files and HF cache persist)

## Required environment variables

This compose file expects:

- `MODEL_FOLDER=/data/sllm-models` (persistent storage)
- `HF_CACHE_FOLDER=/data/hf-cache` (persistent HF cache)

Example:

```bash
export MODEL_FOLDER=/data/sllm-models
export HF_CACHE_FOLDER=/data/hf-cache
mkdir -p "$MODEL_FOLDER" "$HF_CACHE_FOLDER"