# vLLM FastStart via ServerlessLLM Store — Repeatable Runbook (NVMe + Offline Proof)

This is a step-by-step runbook to reproduce the restart benchmark and to *prove* whether a speedup is real
(or inflated because baseline is downloading from Hugging Face).

We compare:
- **baseline**: vLLM loads model via Hugging Face (normal path)
- **faststart**: vLLM loads a **ServerlessLLM Store** formatted model (`--load-format serverless_llm`)

## What we measure (important)
The benchmark scripts measure:
- **ready time**: time until `GET /v1/models` returns 200
- **first completion**: latency for one request after ready

✅ ServerlessLLM Store is primarily about **startup / restart latency** (serverless/batch/autoscaling).
❌ It does **not** make per-token inference faster (that’s kernels / attention / batching / CUDA graphs, etc).

---

## Critical gotchas (read once)
### 1) Your shell does NOT automatically load `.env`
If you run `echo $HF_CACHE_FOLDER` and get empty, that’s normal unless you explicitly load it.

For manual commands:
```bash
set -a; source ./.env; set +a

The benchmark scripts load .env themselves, but your interactive shell does not.
```

### 2) Don’t mount NVMe under /mnt on Azure

/mnt is usually an Azure temporary disk mount and can be reset or wiped.
Mount NVMe at /nvme (or /data_nvme), not /mnt/nvme.

3) Don’t keep OFFLINE enabled in common.env

If HF_HUB_OFFLINE=1 is always on, baseline will crash-loop whenever the HF cache is missing.
That looks like a hang, but it’s actually “never becomes ready”.

⸻

One-time repo change (REQUIRED for sanity)

#### A) Remove offline flags from vllm_bridge/env/common.env

Edit vllm_bridge/env/common.env and DELETE these lines:

```env
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1
```

Offline should be enabled only for the “proof run”, not always.

#### B) Optional but recommended: Make offline togglable without editing files

Add this to each service in vllm_bridge/docker-compose.yml (baseline/faststart/store/convert_model):

```yaml
environment:
  HF_HUB_OFFLINE: ${HF_HUB_OFFLINE:-0}
  TRANSFORMERS_OFFLINE: ${TRANSFORMERS_OFFLINE:-0}
```

Then you can run offline tests like:

```bash
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 ./benchmarks/run_fastrestart_bench.sh ...
```

If you don’t do this optional change, then enabling offline requires editing .env or common.env
(which is exactly what caused repeated breakage).

⸻

#### Step 0 — Clean up any old containers

From repo root:

```bash
docker rm -f vllm_baseline vllm_faststart sllm_store convert_model 2>/dev/null || true
docker compose -f vllm_bridge/docker-compose.yml --env-file .env down --remove-orphans || true
```

⸻

#### Step 1 — Mount NVMe (and VERIFY it is real NVMe)

##### 1.1 Identify NVMe and filesystem state
```bash
lsblk -f | egrep 'NAME|nvme0n1'
sudo file -s /dev/nvme0n1
```

	•	If file -s prints data, it’s unformatted → you must mkfs.
	•	If it prints ext4 filesystem data, it’s already formatted.

##### 1.2 Format only if needed (DANGEROUS: wipes NVMe)

```bash
sudo mkfs.ext4 -F /dev/nvme0n1
```

##### 1.3 Mount to /nvme (DO NOT suppress errors)

```bash
sudo mkdir -p /nvme
sudo umount /nvme 2>/dev/null || true
sudo mount /dev/nvme0n1 /nvme
```

##### 1.4 HARD STOP check (this is the #1 source of confusion)

```bash
df -hT /nvme
mount | grep ' /nvme ' || true
```

✅ Correct looks like:
	•	df shows /dev/nvme0n1 mounted on /nvme

❌ Wrong looks like:
	•	df shows /dev/root for /nvme
→ you are writing to the OS disk and your results are meaningless.

⸻

#### Step 2 — Set your .env correctly

In repo root .env set (example):

```env
MODEL_FOLDER=/nvme/sllm-models
HF_CACHE_FOLDER=/nvme/hf-cache

MODEL_NAME=meta-llama/Llama-3.1-8B-Instruct
MEM_POOL_SIZE=32GB

VLLM_BASELINE_PORT=8001
VLLM_FASTSTART_PORT=8082

# Keep these explicit (don’t reference other vars like $HF_TOKEN inside the file)
HF_TOKEN=...redacted...
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

✅ should show /dev/nvme0n1 for both paths

⸻

#### Step 3 — Build the image

```bash
docker compose -f vllm_bridge/docker-compose.yml --env-file .env build vllm_faststart
```

#### Step 4 — Convert model to ServerlessLLM Store format (ONLINE)

This creates:
```bash
$MODEL_FOLDER/vllm/<org>/<model_name>/...
```

##### 4.1 Clean any partial previous output (prevents FileExistsError)

```bash
set -a; source ./.env; set +a
rm -rf "$MODEL_FOLDER/vllm/${MODEL_NAME}"
```
##### 4.2 Run conversion (force online for this step)
```bash
docker compose -f vllm_bridge/docker-compose.yml --env-file .env \
  --profile tools run -T --rm \
  -e HF_HUB_OFFLINE=0 -e TRANSFORMERS_OFFLINE=0 \
  convert_model
```

##### 4.3 Verify conversion output exists
```bash
set -a; source ./.env; set +a
ls -lah "$MODEL_FOLDER/vllm/${MODEL_NAME}" | head -n 50
```

If this directory is missing → conversion did not write to your mounted volume.

⸻

##### Step 5 — Warm the HF cache (ONLINE, one time)

This is required if you want to do an offline proof run later.

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

Verify the cache actually has the config somewhere:

```bash
set -a; source ./.env; set +a
find "$HF_CACHE_FOLDER" -maxdepth 8 -name config.json | grep -i "Llama-3.1-8B-Instruct" | head
```

If this prints nothing, the cache is not populated where you think it is.

⸻

##### Step 6 — Run the restart benchmark (ONLINE first)

This should reproduce the general behavior reliably.

```bash
./benchmarks/run_fastrestart_bench.sh --runs 3 --drop-caches \
  --note "H100 NVMe tuned store: threads=16 chunk=128MB, pagecache dropped"
```

This is the run that previously produced your 3.26× number:
	•	baseline restart ready ~ 89s
	•	faststart restart ready ~ 27s

⚠️ That big speedup is suspicious unless we PROVE baseline was not downloading.
That’s what the offline proof run is for.

##### Step 7 — OFFLINE proof run (no downloads allowed)

Goal: prove the restart measurement is not inflated by HF downloading / retries / HEAD calls.

7.1 Preconditions (must be true or baseline will crash-loop)
	•	Store-format model exists:
"$MODEL_FOLDER/vllm/$MODEL_NAME" must exist
	•	HF cache contains the model snapshot (the find ... config.json in Step 5 must return something)

7.2 Run offline benchmark

If you applied the optional compose environment: mapping:

```bash
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
./benchmarks/run_fastrestart_bench.sh --runs 3 --drop-caches \
  --note "OFFLINE proof: drop caches, no HF downloads"
```

If you did NOT apply the mapping, the only safe way is temporarily setting offline in .env
(and removing it afterward). Do NOT put offline in common.env permanently.

7.3 If “baseline hangs”

It’s almost always a crash-loop.
Check:
```bash
docker ps -a | grep vllm_baseline || true
docker logs --tail=200 vllm_baseline
```
Typical cause:
	•	HF cache is missing → offline mode prevents download → vLLM cannot find config.json.

Fix:
	•	disable offline
	•	run Step 5 again to warm the cache
	•	re-run offline

⸻

Troubleshooting cheatsheet (fast)

A) “/nvme is mounted but df shows /dev/root”

Not mounted. You wrote to OS disk. Redo Step 1, without suppressing mount errors.

B) convert_model fails with File exists .../original

You have partial output. Run:

```bash
rm -rf "$MODEL_FOLDER/vllm/$MODEL_NAME"
```

Then rerun conversion.

C) HF_CACHE_FOLDER is empty when you echo it

You didn’t load .env into your shell:

```bash
set -a; source ./.env; set +a
```

D) 3× speedup disappears in OFFLINE run

That means the 3× was inflated by baseline doing something extra (often network calls).
That’s the whole reason we do the offline proof run.

⸻

Security note

Do not commit .env. If an HF token was pasted into chat/logs, rotate it.

---

# Why your baseline “hangs” with offline right now (plain English)

Because **you enabled offline globally in `common.env`**, so baseline can’t download after any cache loss. With `restart: unless-stopped`, the container often **crash-loops forever**, and the benchmark script keeps waiting for `/v1/models` → it feels like a hang.

That’s not you. That’s your config.

---

# What to do next (exact order)

1) **Remove offline lines from `vllm_bridge/env/common.env`** (required).  
2) **Mount NVMe correctly** and confirm `df -hT /nvme` shows `/dev/nvme0n1`.  
3) Ensure `.env` points to `/nvme/...` and verify `df -hT "$MODEL_FOLDER" "$HF_CACHE_FOLDER"` shows NVMe.  
4) Run **conversion** (online).  
5) Run **baseline once online** to populate HF cache.  
6) Run the benchmark **online** (sanity).  
7) Run the benchmark **offline proof**.

If you want, I’ll also give you a tiny `vllm_bridge/scripts/check_env.sh` that prints “STOP” in red when you’re accidentally writing to `/dev/root` instead of NVMe — that one guard eliminates 70% of the chaos you’ve hit.
