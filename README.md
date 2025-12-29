This is your README with only the above fixes + a couple clarifying lines. It’s still “yours”, just cleaned up and unambiguous.

# vLLM FastStart via ServerlessLLM Store — Repeatable Runbook (NVMe + Offline Proof)

This is a step-by-step runbook to reproduce the restart benchmark and to prove whether a speedup is real
(or inflated because baseline is downloading from Hugging Face).

We compare:
- **baseline**: vLLM loads model via Hugging Face (normal path)
- **faststart**: vLLM loads a **ServerlessLLM Store** formatted model (`--load-format serverless_llm`)

## What we measure (important)
The benchmark scripts measure:
- **ready time**: time until `GET /v1/models` returns 200
- **first completion**: latency for one request after ready

ServerlessLLM Store is primarily about **startup / restart latency** (serverless/batch/autoscaling).
It does **not** make per-token inference faster (that’s kernels / attention / batching / CUDA graphs, etc).

---

## Critical gotchas (read once)

### 1) Your shell does NOT automatically load `.env`
If you run `echo $HF_CACHE_FOLDER` and get empty, that’s normal unless you explicitly load it.

For manual commands:

```bash
set -a; source ./.env; set +a
```

The benchmark scripts load .env themselves, but your interactive shell does not.

2) Don’t mount NVMe under /mnt on Azure

/mnt is usually an Azure temporary disk mount and can be reset or wiped.
Mount NVMe at /nvme (or /data_nvme), not /mnt/nvme.

3) Don’t keep OFFLINE enabled in common.env

If HF_HUB_OFFLINE=1 is always on, baseline will crash-loop whenever the HF cache is missing.
That looks like a hang, but it’s actually “never becomes ready”.

⸻

One-time repo change (required for sanity)

A) Remove offline flags from vllm_bridge/env/common.env

Edit vllm_bridge/env/common.env and DELETE these lines:

```env
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1
```

Offline should be enabled only for the proof run, not always.

B) Optional but recommended: Make offline togglable without editing files

Add this to each service in vllm_bridge/docker-compose.yml (baseline/faststart/store/convert_model).

Recommended (avoid duplication) — add once at top:

```yaml
x-offline-env: &offline_env
  HF_HUB_OFFLINE: ${HF_HUB_OFFLINE:-0}
  TRANSFORMERS_OFFLINE: ${TRANSFORMERS_OFFLINE:-0}
```
Then in each service:

```yaml
environment: *offline_env
```

Now you can run offline tests like:
```bash
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 ./benchmarks/run_fastrestart_bench.sh ...
```

If you don’t do this, enabling offline requires editing .env or common.env (which caused repeated breakage).

⸻

Step 0 — Clean up old containers

From repo root:
```bash
docker rm -f vllm_baseline vllm_faststart sllm_store convert_model 2>/dev/null || true
docker compose -f vllm_bridge/docker-compose.yml --env-file .env down --remove-orphans || true
```

⸻

Step 1 — Mount NVMe (and VERIFY it is real NVMe)

1.1 Identify NVMe and filesystem state
```bash
lsblk -f | egrep 'NAME|nvme0n1'
sudo file -s /dev/nvme0n1
```
	•	If file -s prints data, it’s unformatted → you must mkfs.
	•	If it prints ext4 filesystem data, it’s already formatted.

1.2 Format only if needed (DANGEROUS: wipes NVMe)
```bash
sudo mkfs.ext4 -F /dev/nvme0n1
```

1.3 Mount to /nvme (DO NOT suppress errors)
```bash
sudo mkdir -p /nvme
sudo umount /nvme 2>/dev/null || true
sudo mount /dev/nvme0n1 /nvme
```
1.4 HARD STOP check (this is the #1 source of confusion)
```bash
df -hT /nvme
findmnt -no SOURCE,TARGET /nvme
```
✅ Correct: /dev/nvme0n1 /nvme
❌ Wrong: anything like /dev/root /nvme → you are writing to OS disk and results are meaningless.

⸻

Step 2 — Set your .env correctly

In repo root .env:
```env
MODEL_FOLDER=/nvme/sllm-models
HF_CACHE_FOLDER=/nvme/hf-cache

MODEL_NAME=meta-llama/Llama-3.1-8B-Instruct
MEM_POOL_SIZE=32GB

VLLM_BASELINE_PORT=8001
VLLM_FASTSTART_PORT=8082

# Keep these explicit (don’t reference other vars like $HF_TOKEN inside the file)
HUGGINGFACE_HUB_TOKEN=...redacted...

SLLM_NUM_THREAD=16
SLLM_CHUNK_SIZE=128MB
```
Create folders:
```bash
set -a; source ./.env; set +a
sudo mkdir -p "$MODEL_FOLDER" "$HF_CACHE_FOLDER"
sudo chown -R "$USER:$USER" "$MODEL_FOLDER" "$HF_CACHE_FOLDER"
```
Verify both are on NVMe:
```bash
df -hT "$MODEL_FOLDER" "$HF_CACHE_FOLDER"
```

⸻

Step 3 — Build the image
```bash
docker compose -f vllm_bridge/docker-compose.yml --env-file .env build vllm_faststart
```

⸻

Step 4 — Convert model to ServerlessLLM Store format (ONLINE)

This creates:
$MODEL_FOLDER/vllm/<org>/<model_name>/...

Note: convert_model may download into a temporary directory and does not guarantee your HF cache is warmed.
Step 5 is still required for offline proof runs.

4.1 Clean any partial previous output (prevents FileExistsError)
```bash
set -a; source ./.env; set +a
rm -rf "$MODEL_FOLDER/vllm/${MODEL_NAME}"
```
4.2 Run conversion (force online for this step)
```bash
docker compose -f vllm_bridge/docker-compose.yml --env-file .env \
  --profile tools run -T --rm \
  -e HF_HUB_OFFLINE=0 -e TRANSFORMERS_OFFLINE=0 \
  convert_model
```
4.3 Verify conversion output exists
```bash
set -a; source ./.env; set +a
ls -lah "$MODEL_FOLDER/vllm/${MODEL_NAME}" | head -n 50
```
If missing → conversion didn’t write to your mounted volume.

⸻

Step 5 — Warm the HF cache (ONLINE, one time)

Required if you want an offline proof run later.

Start baseline once online:
```bash
docker compose -f vllm_bridge/docker-compose.yml --env-file .env --profile baseline up -d vllm_baseline
```
Wait for ready:
```bash
curl -sSf "http://127.0.0.1:${VLLM_BASELINE_PORT}/v1/models" >/dev/null && echo "baseline ready"
```
Stop it:
```bash
docker rm -f vllm_baseline
```
Verify the cache actually contains the config:
```bash
set -a; source ./.env; set +a
find "$HF_CACHE_FOLDER" -name config.json | grep -i "Llama-3.1-8B-Instruct" | head
```
If this prints nothing → offline baseline will crash-loop.

⸻

Step 6 — Run the restart benchmark (ONLINE first)
```bash
./benchmarks/run_fastrestart_bench.sh --runs 3 --drop-caches \
  --note "H100 NVMe tuned store: threads=16 chunk=128MB, pagecache dropped"
```

⸻

Step 7 — OFFLINE proof run (no downloads allowed)

Goal: prove restart measurements are not inflated by HF downloads / retries / HEAD calls.

7.1 Preconditions
	•	Store-format model exists: "$MODEL_FOLDER/vllm/$MODEL_NAME"
	•	HF cache is warmed (Step 5 must find config.json)

7.2 Run offline benchmark
```bash
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
./benchmarks/run_fastrestart_bench.sh --runs 3 --drop-caches \
  --note "OFFLINE proof: drop caches, no HF downloads"
```
7.3 If baseline “hangs”

It’s almost always a crash-loop. Check:

```bash
docker ps -a | grep vllm_baseline || true
docker logs --tail=200 vllm_baseline
```

Typical cause: HF cache missing → offline prevents download → vLLM can’t find config.json.

Fix: disable offline → run Step 5 again → rerun offline.

⸻

Security note

Do not commit .env. If an HF token was pasted into chat/logs, rotate it.

---

## Final thought before you run
The **only** thing I’d insist you do before running is:
- fix the broken code fence
- add `findmnt` check
- add the “convert_model doesn’t warm HF cache” note

Those three prevent the exact “I’m drained and lost” failure mode.

If you want, paste your updated compose snippet after you add the `x-offline-env` anchor and I’ll sanity-check it in 30 seconds (specifically: that offline flags actually reach baseline during the proof run).