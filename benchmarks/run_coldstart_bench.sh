#!/usr/bin/env bash
set -euo pipefail

RUNS=3
DROP_CACHES=0
NOTE=""

usage() {
  cat <<USAGE
Usage: $0 [--runs N] [--drop-caches] [--note "text"]

  --runs N         Number of repeated runs (default: 3)
  --drop-caches    Drop Linux page cache between runs (requires sudo)
  --note "text"    Freeform note stored in the README table

Examples:
  $0 --runs 3
  $0 --runs 3 --note "Azure T4, ubuntu 22.04"
  $0 --runs 3 --drop-caches --note "cold cache"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:-}"; shift 2 ;;
    --drop-caches) DROP_CACHES=1; shift 1 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[bench] ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "[bench] ERROR: --runs must be a positive integer" >&2
  exit 2
fi

if [[ -z "${MODEL_FOLDER:-}" ]]; then
  echo "[bench] ERROR: MODEL_FOLDER is not set (example: export MODEL_FOLDER=/data/sllm-models)" >&2
  exit 2
fi

if [[ -z "${HF_CACHE_FOLDER:-}" ]]; then
  echo "[bench] ERROR: HF_CACHE_FOLDER is not set (example: export HF_CACHE_FOLDER=/data/hf-cache)" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "[bench] ERROR: git repo root not found. Run inside the repo." >&2
  exit 2
fi

COMPOSE_FILE="$REPO_ROOT/vllm_bridge/docker-compose.yml"
README_FILE="$REPO_ROOT/benchmarks/README.md"
RESULTS_DIR="$REPO_ROOT/benchmarks/results"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[bench] ERROR: compose file not found: $COMPOSE_FILE" >&2
  exit 2
fi

if [[ ! -f "$README_FILE" ]]; then
  echo "[bench] ERROR: README not found: $README_FILE" >&2
  exit 2
fi

mkdir -p "$RESULTS_DIR"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
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
      echo "[bench] ERROR: timed out waiting for: $url" >&2
      return 1
    fi
    sleep 0.2
  done
}

drop_caches_if_requested() {
  if [[ "$DROP_CACHES" -eq 1 ]]; then
    echo "[bench] Dropping Linux page cache (requires sudo)..."
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  fi
}

hard_reset() {
  # Your compose uses fixed container_name, so be explicit.
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f vllm_baseline vllm_faststart >/dev/null 2>&1 || true
}

measure_profile_json() {
  local profile="$1" service="$2" port="$3"
  local url_models="http://127.0.0.1:${port}/v1/models"
  local url_chat="http://127.0.0.1:${port}/v1/chat/completions"

  local ready_ms_list=()
  local first_s_list=()

  for i in $(seq 1 "$RUNS"); do
    echo ""
    echo "[bench] ${profile} run ${i}/${RUNS}"

    hard_reset
    drop_caches_if_requested

    local start end delta
    start="$(now_ms)"
    compose --profile "$profile" up -d "$service" >/dev/null
    wait_ready "$url_models" 1200
    end="$(now_ms)"
    delta=$((end - start))

    local t
    t="$(curl -s -o /dev/null -w "%{time_total}" \
      "$url_chat" \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32}')"

    echo "[bench] ${profile} time-to-ready: ${delta} ms"
    echo "[bench] ${profile} first completion: ${t} s"

    ready_ms_list+=("$delta")
    first_s_list+=("$t")

    hard_reset
    sleep 1
  done

  # SAFE JSON: parse from whitespace-separated strings (no IFS trickery).
  python3 - <<PY
import json
ready_s = """${ready_ms_list[*]}""".strip()
first_s = """${first_s_list[*]}""".strip()
ready = [int(x) for x in ready_s.split()] if ready_s else []
first = [float(x) for x in first_s.split()] if first_s else []
print(json.dumps({"ready_ms": ready, "first_s": first}))
PY
}

# Require BENCHMARKS markers in README
if ! grep -q '<!-- BENCHMARKS:START -->' "$README_FILE" || ! grep -q '<!-- BENCHMARKS:END -->' "$README_FILE"; then
  echo "[bench] ERROR: benchmarks/README.md is missing BENCHMARKS markers." >&2
  echo "Add this block somewhere in benchmarks/README.md:" >&2
  cat >&2 <<'MARKERS'
<!-- BENCHMARKS:START -->
| Timestamp (UTC) | Git SHA | Host | GPU | Model | Runs | Baseline ready median (ms) | Faststart ready median (ms) | Ready speedup (x) | Baseline first completion median (s) | Faststart first completion median (s) | Notes | Raw |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
<!-- BENCHMARKS:END -->
MARKERS
  exit 2
fi

# Faststart needs the converted store-format model
if [[ ! -d "$MODEL_FOLDER/vllm/Qwen/Qwen3-0.6B" ]]; then
  echo "[bench] ERROR: missing store-format model at:" >&2
  echo "  $MODEL_FOLDER/vllm/Qwen/Qwen3-0.6B" >&2
  echo "[bench] Run conversion:" >&2
  echo "  docker compose -f vllm_bridge/docker-compose.yml --profile tools run -T --rm convert_qwen3_0_6b" >&2
  exit 2
fi

TS_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
HOSTNAME="$(hostname || echo "unknown")"
GPU="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n 1 || echo "unknown")"
MODEL="Qwen/Qwen3-0.6B"

echo "[bench] Repo: $REPO_ROOT"
echo "[bench] MODEL_FOLDER=$MODEL_FOLDER"
echo "[bench] HF_CACHE_FOLDER=$HF_CACHE_FOLDER"
echo "[bench] RUNS=$RUNS DROP_CACHES=$DROP_CACHES NOTE='${NOTE}'"

# Ensure image exists (no-op if already built)
compose build vllm_faststart >/dev/null

echo ""
echo "[bench] ===== BASELINE ====="
BASELINE_JSON="$(measure_profile_json baseline vllm_baseline 8001)"

echo ""
echo "[bench] ===== FASTSTART ====="
FASTSTART_JSON="$(measure_profile_json faststart vllm_faststart 8000)"

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
RAW_FILE="coldstart_${SAFE_TS}.json"
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
  "baseline": json.loads('''$BASELINE_JSON'''),
  "faststart": json.loads('''$FASTSTART_JSON'''),
  "summary": {
    "baseline_ready_median_ms": float("$BASE_READY_MED"),
    "faststart_ready_median_ms": float("$FAST_READY_MED"),
    "ready_speedup_x": float("$SPEEDUP"),
    "baseline_first_completion_median_s": float("$BASE_FIRST_MED"),
    "faststart_first_completion_median_s": float("$FAST_FIRST_MED"),
  },
}
with open("$RAW_PATH", "w") as f:
  json.dump(out, f, indent=2)
print("[bench] wrote", "$RAW_PATH")
PY

python3 - <<PY
from pathlib import Path
readme = Path("$README_FILE")
lines = readme.read_text().splitlines()

start = "<!-- BENCHMARKS:START -->"
end = "<!-- BENCHMARKS:END -->"
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
print("[bench] updated benchmarks/README.md")
PY

echo ""
echo "[bench] DONE"
echo "[bench] baseline ready median (ms):  $BASE_READY_MED"
echo "[bench] faststart ready median (ms): $FAST_READY_MED"
echo "[bench] ready speedup (x):          $(python3 - <<PY
x=float("$SPEEDUP")
print(f"{x:.2f}")
PY
)"
echo "[bench] baseline first completion:   $BASE_FIRST_MED s"
echo "[bench] faststart first completion:  $FAST_FIRST_MED s"
echo "[bench] raw results:                benchmarks/results/$RAW_FILE"
echo "[bench] table updated:              benchmarks/README.md"
