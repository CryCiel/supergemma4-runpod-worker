
#!/usr/bin/env bash
set -Eeuo pipefail

cd /work

echo "Starting SuperGemma4 RunPod Worker..."

SERVER_PID=""
TAIL_PID=""

cleanup() {
    echo "Cleaning up worker processes..."
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$TAIL_PID" ]]; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 143' SIGTERM
trap 'exit 130' SIGINT

# Require explicit configuration
: "${LLAMA_CACHED_MODEL:?Missing LLAMA_CACHED_MODEL}"
: "${LLAMA_CACHED_GGUF_PATH:?Missing LLAMA_CACHED_GGUF_PATH}"
: "${LLAMA_SERVER_CMD_ARGS:?Missing LLAMA_SERVER_CMD_ARGS}"

# Resolve the cached GGUF file
MODEL_PATH="$(python - <<'PY'
import os
import sys
from pathlib import Path

root = Path("/runpod-volume/huggingface-cache/hub")

repo = os.environ["LLAMA_CACHED_MODEL"]
filename = os.environ["LLAMA_CACHED_GGUF_PATH"]

expected = "models--" + repo.replace("/", "--")

if not root.is_dir():
    print(f"ERROR: Cache directory missing: {root}", file=sys.stderr)
    sys.exit(1)

for folder in root.glob("models--*"):
    if folder.name.casefold() != expected.casefold():
        continue

    snapshots = folder / "snapshots"

    for snapshot in snapshots.glob("*"):
        candidate = snapshot / filename

        if candidate.is_file():
            print(candidate.resolve())
            sys.exit(0)

print(f"ERROR: GGUF not found: {repo}/{filename}", file=sys.stderr)
sys.exit(1)
PY
)"

echo "Found model: $MODEL_PATH"

# Parse the configured command arguments
read -r -a SERVER_ARGS <<< "$LLAMA_SERVER_CMD_ARGS"

# Port is managed internally
for arg in "${SERVER_ARGS[@]}"; do
    if [[ "$arg" == "--port" || "$arg" == "--host" ]]; then
        echo "ERROR: Do not set --port or --host manually."
        exit 1
    fi
done

echo "Launching llama-server..."

# Send server logs to a file and to RunPod stdout
: > /work/llama.server.log

tail -n +1 -F /work/llama.server.log &
TAIL_PID=$!

LD_LIBRARY_PATH=/app \
/app/llama-server \
    -m "$MODEL_PATH" \
    "${SERVER_ARGS[@]}" \
    --host 127.0.0.1 \
    --port 3098 \
    > /work/llama.server.log 2>&1 &

SERVER_PID=$!

echo "llama-server PID: $SERVER_PID"
echo "Waiting for model initialization..."

# Allow up to 180 seconds for model startup
MAX_START_SECONDS=180

for ((i=1; i<=MAX_START_SECONDS; i++)); do

    # Check whether llama-server exited
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: llama-server terminated."
        wait "$SERVER_PID" || true
        cat /work/llama.server.log
        exit 1
    fi

    # Check whether the HTTP API is ready
    if curl -fsS --max-time 2 \
        http://127.0.0.1:3098/health \
        > /dev/null 2>&1; then

        echo "llama-server is READY."
        echo "Starting RunPod handler..."

        python -u /work/handler.py "$@"
        exit $?
    fi

    sleep 1
done

echo "ERROR: Model initialization timed out."
cat /work/llama.server.log
exit 1
