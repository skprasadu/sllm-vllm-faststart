#!/usr/bin/env bash
set -euo pipefail

# Benchmark: restart latency (baseline vs faststart with sllm_store kept up)
#
# Measures:
# - time-to-ready: from restart command start -> /v1/models returns 200
# - first completion latency: curl time_total for a single chat completion
#
# Assumptions:
# - baseline API exposed on host port 8001 (configurable)
# - faststart API exposed on host port 8082 (configurable; you changed it to 8082)
# - compose services exist: vllm_baseline, sllm_store, vllm_faststart
# - container_name is set in compose so docker restart works by name
#
# Env:
# - MODEL_FOLDER, HF_CACHE_FOLDER from .env or .env.template (or already exported)
# - Optional: VLLM_BASELINE_PORT, VLLM_FASTSTART_PORT

RUNS=5
DROP_CACHES=0
NOTE=""

usage() {
  cat <<USAGE
Usage: $0 [--runs N] [--drop-caches] [--note "text"] [--baseline-port P] [--faststart-port P]

  --runs N            Number of restart iterations per profile (default: 5)
  --drop-caches       Drop Linux page cache before each restart (requires passwordless sudo)
  --note "text"       Freeform note stored in README table + JSON
  --baseline-port P   Baseline vLLM host port (default: 8001)
  --faststart-port P  Faststart vLLM host port (default: 8082)

Examples:
  $0 --runs 5
  $0 --runs 10 --note "Azure T4, ubuntu 22.04"
  $0 --runs 10 --faststart-port 8082 --note "store sidecar kept up"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:-}"; shift 2 ;;
    --drop-caches) DROP_CACHES=1; shift 1 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --baseline-port) VLLM_BASELINE_PORT="${2:-}"; shift 2 ;;
    --faststart-port) VLLM_FASTSTART_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[fastrestart] ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "[fastrestart] ERROR: --runs must be a positive integer" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[fastrestart] ERROR: docker not found in PATH" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[fastrestart] ERROR: curl not found in PATH" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[fastrestart] ERROR: python3 not found in PATH" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "[fastrestart] ERROR: git repo root not found. Run inside the repo." >&2
  exit 2
fi

COMPOSE_FILE="$REPO_ROOT/vllm_bridge/docker-compose.yml"
README_FILE="$REPO_ROOT/benchmarks/README.md"
RESULTS_DIR="$REPO_ROOT/benchmarks/results"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[fastrestart] ERROR: compose file not found: $COMPOSE_FILE" >&2
  exit 2
fi
if [[ ! -f "$README_FILE" ]]; then
  echo "[fastrestart] ERROR: README not found: $README_FILE" >&2
  exit 2
fi
mkdir -p "$RESULTS_DIR"

# Prefer .env, fall back to .env.template (your repo has .env.template)
ENV_FILE=""
if [[ -f "$REPO_ROOT/.env" ]]; then
  ENV_FILE="$REPO_ROOT/.env"
elif [[ -f "$REPO_ROOT/.env.template" ]]; then
  ENV_FILE="$REPO_ROOT/.env.template"
fi

# Load env vars into this script process (so MODEL_FOLDER/HF_CACHE_FOLDER available)
if [[ -n "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Required env vars
if [[ -z "${MODEL_FOLDER:-}" ]]; then
  echo "[fastrestart] ERROR: MODEL_FOLDER is not set." >&2
  echo "[fastrestart] Add it to .env (or export it): MODEL_FOLDER=/data/sllm-models" >&2
  exit 2
fi
if [[ -z "${HF_CACHE_FOLDER:-}" ]]; then
  echo "[fastrestart] ERROR: HF_CACHE_FOLDER is not set." >&2
  echo "[fastrestart] Add it to .env (or export it): HF_CACHE_FOLDER=/data/hf-cache" >&2
  exit 2
fi

# Ports (default faststart = 8082 as you requested)
VLLM_BASELINE_PORT="${VLLM_BASELINE_PORT:-8001}"
VLLM_FASTSTART_PORT="${VLLM_FASTSTART_PORT:-8082}"

# Compose wrapper uses the same env file (so compose sees the same values)
compose() {
  if [[ -n "$ENV_FILE" ]]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

now_ms() { date +%s%3N; }

wait_ready() {
  local url="$1"
  local timeout_s="${2:-1200}"
  local start_s
  start_s="$(date +%s)"
  while true; do
    if curl -sf "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) - start_s > timeout_s )); then
      echo "[fastrestart] ERROR: timed out waiting for: $url" >&2
      return 1
    fi
    sleep 0.2
  done
}

drop_caches_if_requested() {
  if [[ "$DROP_CACHES" -eq 1 ]]; then
    # Fail fast if sudo isn't passwordless (prevents prompts mixing into output)
    if ! sudo -n true 2>/dev/null; then
      echo "[fastrestart] ERROR: --drop-caches requires passwordless sudo (sudo -n)." >&2
      echo "[fastrestart] Either run once with 'sudo -v' or configure NOPASSWD for this command." >&2
      exit 2
    fi
    sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1
  fi
}

hard_reset_all() {
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f vllm_baseline vllm_faststart sllm_store >/dev/null 2>&1 || true
}

warmup_once() {
  local port="$1"
  local url_chat="http://127.0.0.1:${port}/v1/chat/completions"

  # Verify 200, ignore body, capture time_total (but discard it; warmup only)
  local out code t
  out="$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
    "$url_chat" \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"warmup"}],"max_tokens":8}')"
  code="${out%% *}"
  t="${out##* }"
  if [[ "$code" != "200" ]]; then
    echo "[fastrestart] ERROR: warmup request failed (HTTP $code) on port $port" >&2
    exit 2
  fi
  echo "[fastrestart] warmup ok on port $port (time_total=${t}s)" >&2
}

measure_restarts_json() {
  local label="$1" container="$2" port="$3"

  local url_models="http://127.0.0.1:${port}/v1/models"
  local url_chat="http://127.0.0.1:${port}/v1/chat/completions"

  local ready_ms_list=()
  local first_s_list=()

  for i in $(seq 1 "$RUNS"); do
    echo "" >&2
    echo "[fastrestart] ${label} restart ${i}/${RUNS}" >&2

    drop_caches_if_requested

    local start end delta
    start="$(now_ms)"
    docker restart "$container" >/dev/null
    wait_ready "$url_models" 1200
    end="$(now_ms)"
    delta=$((end - start))

    local out code t
    out="$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
      "$url_chat" \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32}')"
    code="${out%% *}"
    t="${out##* }"
    if [[ "$code" != "200" ]]; then
      echo "[fastrestart] ERROR: chat request failed (HTTP $code) after restart on ${label}" >&2
      exit 2
    fi

    echo "[fastrestart] ${label} ready after restart: ${delta} ms" >&2
    echo "[fastrestart] ${label} first completion:     ${t} s" >&2

    ready_ms_list+=("$delta")
    first_s_list+=("$t")

    sleep 1
  done

  # IMPORTANT: only JSON goes to STDOUT (captured by $(...))
  python3 - <<PY
import json
ready_s = """${ready_ms_list[*]}""".strip()
first_s = """${first_s_list[*]}""".strip()
ready = [int(x) for x in ready_s.split()] if ready_s else []
first = [float(x) for x in first_s.split()] if first_s else []
print(json.dumps({"ready_ms": ready, "first_s": first}))
PY
}

# README must contain FASTRESTART markers (separate from coldstart markers)
if ! grep -q '<!-- FASTRESTART:START -->' "$README_FILE" || ! grep -q '<!-- FASTRESTART:END -->' "$README_FILE"; then
  echo "[fastrestart] ERROR: benchmarks/README.md is missing FASTRESTART markers." >&2
  echo "Add this block somewhere in benchmarks/README.md:" >&2
  cat >&2 <<'MARKERS'
<!-- FASTRESTART:START -->
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline restart ready median (ms) | Faststart restart ready median (ms) | Restart speedup (x) | Baseline restart first completion median (s) | Faststart restart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
<!-- FASTRESTART:END -->
MARKERS
  exit 2
fi

# Faststart restart bench requires store-format model
if [[ ! -d "$MODEL_FOLDER/vllm/Qwen/Qwen3-0.6B" ]]; then
  echo "[fastrestart] ERROR: missing store-format model at:" >&2
  echo "  $MODEL_FOLDER/vllm/Qwen/Qwen3-0.6B" >&2
  echo "[fastrestart] Run conversion:" >&2
  echo "  docker compose -f vllm_bridge/docker-compose.yml --profile tools run -T --rm convert_qwen3_0_6b" >&2
  exit 2
fi

TS_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
HOSTNAME="$(hostname || echo "unknown")"
GPU="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n 1 || echo "unknown")"
MODEL="Qwen/Qwen3-0.6B"

echo "[fastrestart] Repo: $REPO_ROOT" >&2
echo "[fastrestart] ENV_FILE=${ENV_FILE:-<none>}" >&2
echo "[fastrestart] MODEL_FOLDER=$MODEL_FOLDER" >&2
echo "[fastrestart] HF_CACHE_FOLDER=$HF_CACHE_FOLDER" >&2
echo "[fastrestart] RUNS=$RUNS DROP_CACHES=$DROP_CACHES NOTE='${NOTE}'" >&2
echo "[fastrestart] baseline port=$VLLM_BASELINE_PORT faststart port=$VLLM_FASTSTART_PORT" >&2

# -------------------------------------------------------------------
# 1) BASELINE: restart vllm_baseline repeatedly (no store)
# -------------------------------------------------------------------
hard_reset_all
compose --profile baseline up -d vllm_baseline >/dev/null
wait_ready "http://127.0.0.1:${VLLM_BASELINE_PORT}/v1/models" 1200
warmup_once "$VLLM_BASELINE_PORT"

echo "" >&2
echo "[fastrestart] ===== BASELINE RESTARTS =====" >&2
BASELINE_JSON="$(measure_restarts_json baseline vllm_baseline "$VLLM_BASELINE_PORT")"

# free GPU
docker rm -f vllm_baseline >/dev/null 2>&1 || true

# -------------------------------------------------------------------
# 2) FASTSTART: keep sllm_store up; restart vllm_faststart repeatedly
# -------------------------------------------------------------------
hard_reset_all

# Ensure patched image exists (no-op if already built)
compose build vllm_faststart >/dev/null

# Bring up store + vLLM once, then only restart vLLM for measurements
compose --profile faststart up -d sllm_store vllm_faststart >/dev/null
wait_ready "http://127.0.0.1:${VLLM_FASTSTART_PORT}/v1/models" 1200
warmup_once "$VLLM_FASTSTART_PORT"

echo "" >&2
echo "[fastrestart] ===== FASTSTART RESTARTS (store kept up) =====" >&2
FASTSTART_JSON="$(measure_restarts_json faststart vllm_faststart "$VLLM_FASTSTART_PORT")"

# shutdown
hard_reset_all

# Compute medians + speedup
BASE_READY_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$BASELINE_JSON''')
print(statistics.median([float(x) for x in d["ready_ms"]]))
PY
)"
FAST_READY_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$FASTSTART_JSON''')
print(statistics.median([float(x) for x in d["ready_ms"]]))
PY
)"
BASE_FIRST_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$BASELINE_JSON''')
print(statistics.median([float(x) for x in d["first_s"]]))
PY
)"
FAST_FIRST_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$FASTSTART_JSON''')
print(statistics.median([float(x) for x in d["first_s"]]))
PY
)"
SPEEDUP="$(python3 - <<PY
b=float("$BASE_READY_MED"); f=float("$FAST_READY_MED")
print(b/f if f > 0 else 0.0)
PY
)"

SAFE_TS="$(date -u +"%Y%m%d_%H%M%S")"
RAW_FILE="fastrestart_${SAFE_TS}.json"
RAW_PATH="$RESULTS_DIR/$RAW_FILE"

python3 - <<PY
import json
out = {
  "timestamp_utc": "$TS_UTC",
  "git_sha": "$GIT_SHA",
  "host": "$HOSTNAME",
  "gpu": "$GPU",
  "model": "$MODEL",
  "runs": $RUNS,
  "drop_caches": bool($DROP_CACHES),
  "note": "$NOTE",
  "ports": {
    "baseline_port": int("$VLLM_BASELINE_PORT"),
    "faststart_port": int("$VLLM_FASTSTART_PORT"),
  },
  "baseline_restart": json.loads('''$BASELINE_JSON'''),
  "faststart_restart": json.loads('''$FASTSTART_JSON'''),
  "summary": {
    "baseline_restart_ready_median_ms": float("$BASE_READY_MED"),
    "faststart_restart_ready_median_ms": float("$FAST_READY_MED"),
    "restart_speedup_x": float("$SPEEDUP"),
    "baseline_restart_first_completion_median_s": float("$BASE_FIRST_MED"),
    "faststart_restart_first_completion_median_s": float("$FAST_FIRST_MED"),
  },
}
with open("$RAW_PATH", "w") as f:
  json.dump(out, f, indent=2)
print("[fastrestart] wrote", "$RAW_PATH")
PY

# Update FASTRESTART table in benchmarks/README.md (prepend row)
python3 - <<PY
from pathlib import Path

readme = Path("$README_FILE")
lines = readme.read_text().splitlines()

start = "<!-- FASTRESTART:START -->"
end = "<!-- FASTRESTART:END -->"

sidx = lines.index(start)
eidx = lines.index(end)

block = lines[sidx+1:eidx]
header = block[0]
sep = block[1]
rows = block[2:]

notes = []
if int("$DROP_CACHES") == 1:
  notes.append("drop_caches=1")
if "$NOTE":
  notes.append("note=" + "$NOTE")
notes.append(f"ports=baseline:{int('$VLLM_BASELINE_PORT')},faststart:{int('$VLLM_FASTSTART_PORT')}")
note_str = ", ".join(notes).replace("|", "\\|")

row = (
  f"| $TS_UTC | $GIT_SHA | $HOSTNAME | $GPU | $MODEL | $RUNS | "
  f"{int(float($BASE_READY_MED))} | {int(float($FAST_READY_MED))} | {float($SPEEDUP):.2f} | "
  f"{float($BASE_FIRST_MED):.3f} | {float($FAST_FIRST_MED):.3f} | "
  f"{note_str} | [json](results/$RAW_FILE) |"
)

new_block = [header, sep, row] + rows
new_lines = lines[:sidx+1] + new_block + lines[eidx:]
readme.write_text("\n".join(new_lines) + "\n")
print("[fastrestart] updated benchmarks/README.md")
PY

echo "" >&2
echo "[fastrestart] DONE" >&2
echo "[fastrestart] baseline restart ready median (ms):   $BASE_READY_MED" >&2
echo "[fastrestart] faststart restart ready median (ms):  $FAST_READY_MED" >&2
echo "[fastrestart] restart speedup (x):                 $(python3 - <<PY
x=float("$SPEEDUP")
print(f"{x:.2f}")
PY
)" >&2
echo "[fastrestart] baseline restart first completion:    $BASE_FIRST_MED s" >&2
echo "[fastrestart] faststart restart first completion:   $FAST_FIRST_MED s" >&2
echo "[fastrestart] raw results:                          benchmarks/results/$RAW_FILE" >&2
echo "[fastrestart] table updated:                        benchmarks/README.md" >&2