#!/usr/bin/env bash
set -euo pipefail

: "${STORAGE_PATH:=/models/vllm}"
: "${MEM_POOL_SIZE:=4GB}"
: "${SLLM_STORE_PORT:=8073}"

mkdir -p "${STORAGE_PATH}"

echo "[faststart] Starting sllm-store on ${STORAGE_PATH} (mem pool: ${MEM_POOL_SIZE})..."
sllm-store start --storage-path "${STORAGE_PATH}" --mem-pool-size "${MEM_POOL_SIZE}" &
STORE_PID="$!"

# Wait until the gRPC port is listening
python3 - <<'PY'
import os, socket, time, sys

host = "127.0.0.1"
port = int(os.environ.get("SLLM_STORE_PORT", "8073"))

for i in range(120):
    s = socket.socket()
    s.settimeout(1.0)
    try:
        s.connect((host, port))
        print("[faststart] sllm-store is ready")
        break
    except Exception:
        time.sleep(1)
    finally:
        s.close()
else:
    print("[faststart] ERROR: sllm-store did not become ready in time", file=sys.stderr)
    sys.exit(1)
PY

echo "[faststart] Starting vLLM OpenAI server with args: $*"
exec python3 -m vllm.entrypoints.openai.api_server "$@"