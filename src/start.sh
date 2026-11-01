
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
: "${LLAMA_SERVER_CMD_ARGS:?Missing LLAMA_SERVER_CMD_ARGS}"

# Cached models are optional; direct -hf/-m settings also work.
MODEL_ARGS=()
if [[ -n "${LLAMA_CACHED_MODEL:-}" || -n "${LLAMA_CACHED_GGUF_PATH:-}" ]]; then
    if [[ -z "${LLAMA_CACHED_MODEL:-}" || -z "${LLAMA_CACHED_GGUF_PATH:-}" ]]; then
        echo "ERROR: Set BOTH LLAMA_CACHED_MODEL and LLAMA_CACHED_GGUF_PATH."
        exit 1
    fi
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
    MODEL_ARGS=(-m "$MODEL_PATH")
else
    echo "Using model selection from LLAMA_SERVER_CMD_ARGS."
fi

# Parse the configured command arguments
read -r -a SERVER_ARGS <<< "$LLAMA_SERVER_CMD_ARGS"

# Port is managed internally
for arg in "${SERVER_ARGS[@]}"; do
    case "$arg" in
        --port|--port=*|-p|--host|--host=*)
            echo "ERROR: Do not set --port or --host manually."
            exit 1
            ;;
    esac
    if (( ${#MODEL_ARGS[@]} > 0 )); then
        case "$arg" in
            -m|--model|--model=*|-hf|--hf-repo|--hf-repo=*)
                echo "ERROR: Do not set a model flag with LLAMA_CACHED_MODEL."
                exit 1
                ;;
        esac
    fi
done

if (( ${#MODEL_ARGS[@]} == 0 )); then
    HAS_MODEL=false
    for arg in "${SERVER_ARGS[@]}"; do
        case "$arg" in
            -m|--model|--model=*|-hf|--hf-repo|--hf-repo=*) HAS_MODEL=true ;;
        esac
    done
    if [[ "$HAS_MODEL" != true ]]; then
        echo "ERROR: Set cache variables or specify -hf/-m in LLAMA_SERVER_CMD_ARGS."
        exit 1
    fi
fi

echo "Launching llama-server..."

# Send server logs to a file and to RunPod stdout
: > /work/llama.server.log

tail -n +1 -F /work/llama.server.log &
TAIL_PID=$!

LD_LIBRARY_PATH=/app \
/app/llama-server \
    "${MODEL_ARGS[@]}" \
    "${SERVER_ARGS[@]}" \
    --host 127.0.0.1 \
    --port 3098 \
    > /work/llama.server.log 2>&1 &

SERVER_PID=$!

echo "llama-server PID: $SERVER_PID"
echo "Waiting for model initialization..."

# Allow up to 180 seconds for model startup
MAX_START_SECONDS="${LLAMA_STARTUP_TIMEOUT:-300}"
if ! [[ "$MAX_START_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: LLAMA_STARTUP_TIMEOUT must be a positive integer (seconds)."
    exit 1
fi

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
