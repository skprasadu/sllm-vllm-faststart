#!/usr/bin/env bash
set -euo pipefail

# Benchmark: restart latency (baseline vs faststart with sllm_store kept up)
#
# Measures:
# - time-to-ready: from `docker restart <container>` start -> /v1/models returns 200
# - first completion latency: curl time_total for a single chat completion
#
# Assumptions:
# - baseline API exposed on host port 8001
# - faststart API exposed on host port 8082 (you set this)
# - compose services exist: vllm_baseline, sllm_store, vllm_faststart
# - vllm_faststart uses: network_mode: "service:sllm_store"

RUNS=5
DROP_CACHES=0
NOTE=""
VLLM_BASELINE_PORT="8001"
VLLM_FASTSTART_PORT="8082"
MODEL_NAME="Qwen/Qwen3-0.6B"
MEM_POOL_SIZE="4GB"

usage() {
  cat <<USAGE
Usage: $0 [--runs N] [--drop-caches] [--note "text"] [--baseline-port P] [--faststart-port P]
         [--model MODEL_ID] [--mem-pool-size SIZE]
  --runs N            Number of restart iterations per profile (default: 5)
  --drop-caches       Drop Linux page cache before each restart (requires passwordless sudo)
  --note "text"       Freeform note stored in README table + JSON
  --baseline-port P   Baseline vLLM host port (default: 8001)
  --faststart-port P  Faststart vLLM host port (default: 8082)
  --model MODEL_ID    HF model id (default: Qwen/Qwen3-0.6B)
  --mem-pool-size SZ  sllm-store pinned pool (default: 4GB)

Examples:
  $0 --runs 5
  $0 --runs 3 --note "Azure T4, ubuntu 22.04, store sidecar" --faststart-port 8082
USAGE
}

need_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || { echo "[fastrestart] ERROR: missing command: $c" >&2; exit 2; }
}

need_cmd docker
need_cmd curl
need_cmd python3

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

# Prefer .env, fall back to .env.template
ENV_FILE=""
if [[ -f "$REPO_ROOT/.env" ]]; then
  ENV_FILE="$REPO_ROOT/.env"
elif [[ -f "$REPO_ROOT/.env.template" ]]; then
  ENV_FILE="$REPO_ROOT/.env.template"
fi

# Load env vars FIRST (so CLI args override them)
if [[ -n "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Now parse CLI args (CLI wins)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:-}"; shift 2 ;;
    --drop-caches) DROP_CACHES=1; shift 1 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --baseline-port) VLLM_BASELINE_PORT="${2:-}"; shift 2 ;;
    --faststart-port) VLLM_FASTSTART_PORT="${2:-}"; shift 2 ;;
    --model) MODEL_NAME="${2:-}"; shift 2 ;;
    --mem-pool-size) MEM_POOL_SIZE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[fastrestart] ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

: "${MODEL_NAME:=Qwen/Qwen3-0.6B}"
: "${MEM_POOL_SIZE:=4GB}"
export MODEL_NAME MEM_POOL_SIZE VLLM_BASELINE_PORT VLLM_FASTSTART_PORT

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "[fastrestart] ERROR: --runs must be a positive integer" >&2
  exit 2
fi
if ! [[ "$VLLM_BASELINE_PORT" =~ ^[0-9]+$ ]]; then
  echo "[fastrestart] ERROR: --baseline-port must be numeric" >&2
  exit 2
fi
if ! [[ "$VLLM_FASTSTART_PORT" =~ ^[0-9]+$ ]]; then
  echo "[fastrestart] ERROR: --faststart-port must be numeric" >&2
  exit 2
fi

# Required env vars
if [[ -z "${MODEL_FOLDER:-}" ]]; then
  echo "[fastrestart] ERROR: MODEL_FOLDER is not set." >&2
  echo "[fastrestart] Add it to .env/.env.template or export it (example: MODEL_FOLDER=/data/sllm-models)" >&2
  exit 2
fi
if [[ -z "${HF_CACHE_FOLDER:-}" ]]; then
  echo "[fastrestart] ERROR: HF_CACHE_FOLDER is not set." >&2
  echo "[fastrestart] Add it to .env/.env.template or export it (example: HF_CACHE_FOLDER=/data/hf-cache)" >&2
  exit 2
fi

compose() {
  if [[ -n "$ENV_FILE" ]]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

now_ms() { date +%s%3N; }

wait_http_ready() {
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

wait_store_ready() {
  local timeout_s="${1:-600}"
  local start_s
  start_s="$(date +%s)"
  while true; do
    if docker exec sllm_store python3 -c "import socket; socket.create_connection(('127.0.0.1',8073),timeout=1).close()" >/dev/null 2>&1; then
      echo "[fastrestart] sllm_store is ready on 127.0.0.1:8073" >&2
      return 0
    fi
    if (( $(date +%s) - start_s > timeout_s )); then
      echo "[fastrestart] ERROR: timed out waiting for sllm_store :8073" >&2
      echo "[fastrestart] ---- sllm_store logs (tail 200) ----" >&2
      docker logs --tail=200 sllm_store >&2 || true
      return 1
    fi
    sleep 1
  done
}

drop_caches_if_requested() {
  if [[ "$DROP_CACHES" -eq 1 ]]; then
    if ! sudo -n true 2>/dev/null; then
      echo "[fastrestart] ERROR: --drop-caches requires passwordless sudo (sudo -n)." >&2
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
  local out code t
  out="$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
    "$url_chat" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"warmup\"}],\"max_tokens\":8}")"
  code="${out%% *}"
  t="${out##* }"
  if [[ "$code" != "200" ]]; then
    echo "[fastrestart] ERROR: warmup failed (HTTP $code) on port $port" >&2
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
    wait_http_ready "$url_models" 1200
    end="$(now_ms)"
    delta=$((end - start))

    local out code t
    out="$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
      "$url_chat" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}],\"max_tokens\":32}")"
    code="${out%% *}"
    t="${out##* }"
    if [[ "$code" != "200" ]]; then
      echo "[fastrestart] ERROR: chat failed (HTTP $code) after restart on ${label}" >&2
      exit 2
    fi

    echo "[fastrestart] ${label} ready after restart: ${delta} ms" >&2
    echo "[fastrestart] ${label} first completion:     ${t} s" >&2

    ready_ms_list+=("$delta")
    first_s_list+=("$t")

    sleep 1
  done

  python3 - <<PY
import json
ready = [int(x) for x in """${ready_ms_list[*]}""".strip().split()] if """${ready_ms_list[*]}""".strip() else []
first = [float(x) for x in """${first_s_list[*]}""".strip().split()] if """${first_s_list[*]}""".strip() else []
print(json.dumps({"ready_ms": ready, "first_s": first}))
PY
}

# FASTRESTART table block must exist and contain header+separator
if ! grep -q '<!-- FASTRESTART:START -->' "$README_FILE" || ! grep -q '<!-- FASTRESTART:END -->' "$README_FILE"; then
  echo "[fastrestart] ERROR: benchmarks/README.md is missing FASTRESTART markers." >&2
  exit 2
fi
if [[ "$(awk '/<!-- FASTRESTART:START -->/{f=1;next} /<!-- FASTRESTART:END -->/{f=0} f{print}' "$README_FILE" | wc -l)" -lt 2 ]]; then
  echo "[fastrestart] ERROR: FASTRESTART block exists but has no table header." >&2
  echo "Paste this inside benchmarks/README.md between FASTRESTART markers:" >&2
  cat >&2 <<'HDR'
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline restart ready median (ms) | Faststart restart ready median (ms) | Restart speedup (x) | Baseline restart first completion median (s) | Faststart restart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
HDR
  exit 2
fi

# store-format model must exist
if [[ ! -d "$MODEL_FOLDER/vllm/${MODEL_NAME}" ]]; then
  echo "[fastrestart] ERROR: missing store-format model at: $MODEL_FOLDER/vllm/${MODEL_NAME}" >&2
  echo "[fastrestart] Run conversion:" >&2
  echo "  docker compose -f vllm_bridge/docker-compose.yml --profile tools run -T --rm convert_model" >&2
  exit 2
fi

TS_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
HOSTNAME="$(hostname || echo "unknown")"
GPU="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n 1 || echo "unknown")"
MODEL="$MODEL_NAME"

echo "[fastrestart] Repo: $REPO_ROOT" >&2
echo "[fastrestart] ENV_FILE=${ENV_FILE:-<none>}" >&2
echo "[fastrestart] MODEL_FOLDER=$MODEL_FOLDER" >&2
echo "[fastrestart] HF_CACHE_FOLDER=$HF_CACHE_FOLDER" >&2
echo "[fastrestart] RUNS=$RUNS DROP_CACHES=$DROP_CACHES NOTE='${NOTE}'" >&2
echo "[fastrestart] MODEL_NAME=${MODEL_NAME} MEM_POOL_SIZE=${MEM_POOL_SIZE}" >&2

# ---------------- BASELINE ----------------
hard_reset_all
compose --profile baseline up -d vllm_baseline >/dev/null
wait_http_ready "http://127.0.0.1:${VLLM_BASELINE_PORT}/v1/models" 1200
warmup_once "$VLLM_BASELINE_PORT"

echo "" >&2
echo "[fastrestart] ===== BASELINE RESTARTS =====" >&2
BASELINE_JSON="$(measure_restarts_json baseline vllm_baseline "$VLLM_BASELINE_PORT")"

docker rm -f vllm_baseline >/dev/null 2>&1 || true

# ---------------- FASTSTART (store kept up) ----------------
hard_reset_all
compose build vllm_faststart >/dev/null

# Start store first, wait for gRPC, then start vLLM
compose --profile faststart up -d sllm_store >/dev/null
wait_store_ready 600

compose --profile faststart up -d vllm_faststart >/dev/null
wait_http_ready "http://127.0.0.1:${VLLM_FASTSTART_PORT}/v1/models" 1200
warmup_once "$VLLM_FASTSTART_PORT"

echo "" >&2
echo "[fastrestart] ===== FASTSTART RESTARTS (store kept up) =====" >&2
FASTSTART_JSON="$(measure_restarts_json faststart vllm_faststart "$VLLM_FASTSTART_PORT")"

hard_reset_all

# summary stats
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
  "mem_pool_size": "$MEM_POOL_SIZE",
  "ports": {"baseline_port": int("$VLLM_BASELINE_PORT"), "faststart_port": int("$VLLM_FASTSTART_PORT")},
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