#!/usr/bin/env bash
set -euo pipefail

# Benchmarks baseline vs faststart cold-start time-to-ready + first completion latency.
#
# Requirements:
# - Run from repo root OR anywhere (script finds repo root via git).
# - Env vars: MODEL_FOLDER and HF_CACHE_FOLDER must be set.
# - benchmarks/README.md must exist and include BENCHMARKS markers.

RUNS=3
DROP_CACHES=0
NOTE=""

usage() {
  cat <<EOF
Usage: $0 [--runs N] [--drop-caches] [--note "text"]

  --runs N         Number of repeated runs (default: 3)
  --drop-caches    Drop Linux page cache between runs (requires sudo)
  --note "text"    Freeform note appended into the benchmark table

Examples:
  $0 --runs 3
  $0 --runs 5 --note "Azure T4, Ubuntu 22.04"
  $0 --runs 3 --drop-caches --note "cold disk cache"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --drop-caches)
      DROP_CACHES=1
      shift 1
      ;;
    --note)
      NOTE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[bench] ERROR: unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "[bench] ERROR: --runs must be a positive integer" >&2
  exit 2
fi

if [[ -z "${MODEL_FOLDER:-}" ]]; then
  echo "[bench] ERROR: MODEL_FOLDER is not set. Example:" >&2
  echo "  export MODEL_FOLDER=/data/sllm-models" >&2
  exit 2
fi

if [[ -z "${HF_CACHE_FOLDER:-}" ]]; then
  echo "[bench] ERROR: HF_CACHE_FOLDER is not set. Example:" >&2
  echo "  export HF_CACHE_FOLDER=/data/hf-cache" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[bench] ERROR: docker not found in PATH" >&2
  exit 2
fi

# Find repo root (prefer git)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  echo "[bench] ERROR: could not find repo root (git rev-parse failed). Run inside the repo." >&2
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
  echo "[bench] ERROR: missing $README_FILE" >&2
  echo "[bench] Please create it with the BENCHMARKS markers (see instructions in chat)." >&2
  exit 2
fi

mkdir -p "$RESULTS_DIR"

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

now_ms() { date +%s%3N; }

median() {
  # usage: median 1 2 3 ...
  python3 - "$@" <<'PY'
import sys, statistics
vals = [float(x) for x in sys.argv[1:]]
if not vals:
  print("nan"); raise SystemExit(0)
print(statistics.median(vals))
PY
}

fmt2() {
  python3 - "$1" <<'PY'
import sys
x=float(sys.argv[1])
print(f"{x:.2f}")
PY
}

wait_ready() {
  local url="$1"
  local timeout_s="${2:-900}"
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

measure_profile() {
  local profile="$1"     # baseline|faststart
  local service="$2"     # vllm_baseline|vllm_faststart
  local port="$3"        # 8001|8000

  local url_models="http://127.0.0.1:${port}/v1/models"
  local url_chat="http://127.0.0.1:${port}/v1/chat/completions"

  local ready_ms_list=()
  local first_s_list=()

  for i in $(seq 1 "$RUNS"); do
    echo ""
    echo "[bench] ${profile} run ${i}/${RUNS}"

    compose down --remove-orphans >/dev/null 2>&1 || true
    drop_caches_if_requested

    local start end delta
    start="$(now_ms)"
    compose --profile "$profile" up -d "$service" >/dev/null
    wait_ready "$url_models" 1200
    end="$(now_ms)"
    delta=$((end - start))

    # first completion time_total
    local t
    t="$(curl -s -o /dev/null -w "%{time_total}" \
      "$url_chat" \
      -H "Content-Type: application/json" \
      -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Say hello in one short sentence."}],"max_tokens":32}')"

    echo "[bench] ${profile} time-to-ready: ${delta} ms"
    echo "[bench] ${profile} first completion: ${t} s"

    ready_ms_list+=("$delta")
    first_s_list+=("$t")

    compose down --remove-orphans >/dev/null 2>&1 || true
    sleep 1
  done

  # Print arrays as JSON-ish lines for caller to capture
  python3 - <<PY
import json
print(json.dumps({
  "ready_ms": ${ready_ms_list[@]+["$(IFS='","'; echo "${ready_ms_list[*]}")"]},
  "first_s":  ${first_s_list[@]+["$(IFS='","'; echo "${first_s_list[*]}")"]},
}))
PY
}

echo "[bench] Repo: $REPO_ROOT"
echo "[bench] MODEL_FOLDER=$MODEL_FOLDER"
echo "[bench] HF_CACHE_FOLDER=$HF_CACHE_FOLDER"
echo "[bench] RUNS=$RUNS DROP_CACHES=$DROP_CACHES NOTE='${NOTE}'"

# Metadata
TS_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
HOSTNAME="$(hostname || echo "unknown")"
GPU="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n 1 || echo "unknown")"
MODEL="Qwen/Qwen3-0.6B"

# Run baseline then faststart (single GPU safe)
echo ""
echo "[bench] ===== BASELINE ====="
BASELINE_JSON="$(measure_profile baseline vllm_baseline 8001)"

echo ""
echo "[bench] ===== FASTSTART ====="
FASTSTART_JSON="$(measure_profile faststart vllm_faststart 8000)"

# Compute medians
BASE_READY_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$BASELINE_JSON''')
vals=[float(x) for x in d["ready_ms"]]
print(statistics.median(vals))
PY
)"
FAST_READY_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$FASTSTART_JSON''')
vals=[float(x) for x in d["ready_ms"]]
print(statistics.median(vals))
PY
)"

BASE_FIRST_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$BASELINE_JSON''')
vals=[float(x) for x in d["first_s"]]
print(statistics.median(vals))
PY
)"
FAST_FIRST_MED="$(python3 - <<PY
import json, statistics
d=json.loads('''$FASTSTART_JSON''')
vals=[float(x) for x in d["first_s"]]
print(statistics.median(vals))
PY
)"

SPEEDUP="$(python3 - <<PY
b=float("$BASE_READY_MED")
f=float("$FAST_READY_MED")
print(b/f if f > 0 else 0.0)
PY
)"

# Write raw results JSON
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
print("$RAW_PATH")
PY

# Update benchmarks/README.md table (insert row at top of table block)
python3 - <<PY
from pathlib import Path

readme = Path("$README_FILE")
text = readme.read_text().splitlines()

start = "<!-- BENCHMARKS:START -->"
end = "<!-- BENCHMARKS:END -->"

if start not in text or end not in text:
  raise SystemExit("[bench] ERROR: README is missing BENCHMARKS markers")

sidx = text.index(start)
eidx = text.index(end)
block = text[sidx+1:eidx]

if len(block) < 2:
  raise SystemExit("[bench] ERROR: BENCHMARKS block must contain a table header + separator")

header = block[0]
sep = block[1]
rest = block[2:]

row = (
  f"| {\"$TS_UTC\"} | {\"$GIT_SHA\"} | {\"$HOSTNAME\"} | {\"$GPU\"} | {\"$MODEL\"} | {\"$RUNS\"} | "
  f"{int(float(\"$BASE_READY_MED\"))} | {int(float(\"$FAST_READY_MED\"))} | {float(\"$SPEEDUP\"):.2f} | "
  f"{float(\"$BASE_FIRST_MED\"):.3f} | {float(\"$FAST_FIRST_MED\"):.3f} | "
  f"{(\"drop_caches=1, \" if $DROP_CACHES else \"\") + (\"note=\" + \"$NOTE\" if \"$NOTE\" else \"\")} | "
  f"[json](results/{\"$RAW_FILE\"}) |"
)

new_block = [header, sep, row] + rest
new_text = text[:sidx+1] + new_block + text[eidx:]

readme.write_text("\n".join(new_text) + "\n")
print("[bench] Updated benchmarks/README.md and wrote results:", "benchmarks/results/" + "$RAW_FILE")
PY

echo ""
echo "[bench] DONE"
echo "[bench] baseline ready median (ms):  $BASE_READY_MED"
echo "[bench] faststart ready median (ms): $FAST_READY_MED"
echo "[bench] ready speedup (x):          $(fmt2 "$SPEEDUP")"
echo "[bench] baseline first completion:   $BASE_FIRST_MED s"
echo "[bench] faststart first completion:  $FAST_FIRST_MED s"
echo "[bench] raw results:                benchmarks/results/$RAW_FILE"
echo "[bench] table updated:              benchmarks/README.md"