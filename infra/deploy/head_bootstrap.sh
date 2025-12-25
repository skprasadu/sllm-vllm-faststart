#!/usr/bin/env bash
set -euo pipefail

# Start the image's original entrypoint (starts Ray head + SLLM API)
# Keep it running in the background.
 /app/entrypoint.sh "$@" &
PID="$!"

# Wait for the SLLM HTTP API to be reachable
python3 - <<'PY'
import time
import urllib.request

url = "http://127.0.0.1:8343/docs"
for i in range(180):  # ~3 minutes
    try:
        urllib.request.urlopen(url, timeout=1).read()
        print("SLLM API is up")
        break
    except Exception:
        time.sleep(1)
else:
    raise SystemExit("SLLM API did not become ready in time")
PY

# Deploy (register) models every startup.
# This makes your first curl after a restart NOT 500 due to missing actors.
conda run -n head sllm deploy --config /deploy/qwen3-0.6b.warm.json

# Keep container alive by waiting on the original process
wait "$PID"