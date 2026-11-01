<p align="center">
    <img src="https://raw.githubusercontent.com/ggml-org/llama.cpp/master/media/llama1-icon-transparent.png" alt="llama.cpp logo" width="128">
</p>

# Serverless llama.cpp inference worker for RunPod

This repository contains a serverless inference worker for running llama.cpp models on RunPod. It uses the `llama-server` image to provide an API for interacting with the models.
The following OpenAI API endpoints are supported:

- `v1/models`
- `v1/chat/completions`
- `v1/completions`

Streaming responses is also supported.

**Important!** This project is still relatively new. Please [open a new issue](https://github.com/Jacob-ML/inference-worker/issues/new) if you encounter any problems in order to get help.

**This is a fork of [SvenBrnn's `runpod-worker-ollama`](https://github.com/SvenBrnn/runpod-worker-ollama).**

## Setup

To get the best performance out of this worker, it is recommended to use cached models. Please see the [cached models documentation](./docs/cached.md) for more information, this is **highly recommended and will save many resources**.

## Configuration

The worker can be configured via environment variables set in the RunPod hub configuration:

- `LLAMA_SERVER_CMD_ARGS`: Command line arguments (argv) for the `llama-server` binary. Example: `-hf /path/to/model.gguf:Q4_K_M --ctx-size 4096`. **IMPORTANT**: Please do not define the port argument here, as the worker will always use port `3098` automatically.
- `MAX_CONCURRENCY`: Maximum simultaneous RunPod requests. Default is `1` (override for multi-user use).
- `LLAMA_STARTUP_TIMEOUT`: Seconds to wait for llama-server readiness. Default is `300`.

## License

Please see the [LICENSE](./LICENSE) file for more information.

[![Runpod badge](https://api.runpod.io/badge/Jacob-ML/inference-worker)](https://console.runpod.io/hub/Jacob-ML/inference-worker)

## Long-context single-user setup

Use *either* the RunPod model cache or direct model arguments:

- Cache: set **both** `LLAMA_CACHED_MODEL` and `LLAMA_CACHED_GGUF_PATH`, and omit `-m`/`-hf` from `LLAMA_SERVER_CMD_ARGS`.
- Direct: leave both cache variables unset and use `-hf ...` or `-m ...` in `LLAMA_SERVER_CMD_ARGS`.

For one SillyTavern session start with `MAX_CONCURRENCY=1` and `--parallel 1`. Configure a `--ctx-size` that your **actual model and GPU memory** support; the SillyTavern context setting does not expand the server's context. The default GPU list now includes A40 (`AMPERE_48`); the Dockerfile is built for SM 86, so verify other hardware separately.

For RunPod flat jobs (`input.messages` or `input.prompt`), common generation settings including `max_tokens`, `temperature`, `top_p`, `seed` and `stop` are passed to llama-server. OpenAI-style `openai_route`/`openai_input` jobs continue to pass the payload through unchanged.

```json
{
  "input": {
    "messages": [{"role": "user", "content": "긴 이야기를 자연스럽게 이어 주세요."}],
    "max_tokens": 8192,
    "temperature": 0.8,
    "stream": false
  }
}
```

Increasing the `max_tokens` ceiling does **not** automatically make responses longer. Check the completion finish reason (`length` versus `stop`) before increasing it. For large models, set `LLAMA_STARTUP_TIMEOUT` to more than 300 only if startup actually times out.

## GPU build targets (including Blackwell MIG)

The CUDA image builds native kernels for these GPUs, using the pinned llama.cpp
commit and CUDA 12.8.1 toolchain:

| CUDA target | Typical GPU | Notes |
| --- | --- | --- |
| `86-real` | A40 48GB | Existing working configuration |
| `89-real` | L40/L40S, RTX 6000 Ada | Ada 48GB GPUs |
| `120a-real` | RTX PRO 6000 Blackwell MIG 48GB | Blackwell server 2g.48gb MIG slice |

The `-real` targets avoid including redundant PTX targets in the image.
Building for three targets increases build-time compilation work versus an
A40-only build, but does not change the model, prompts, or inference API.

**RunPod GPU selection** is configured separately in the Serverless endpoint
settings. Changing a Hub template `gpuIds` does not reconfigure an already
deployed endpoint. `ADA_48_PRO` is an Ada pool, *not* a Blackwell MIG pool;
do not select it expecting a Blackwell MIG GPU. Keep the exact GPU/pool already
chosen in the endpoint if it is working.

**Context capacity:** `--ctx-size 262144` is a `llama-server` runtime
setting, not a Docker build setting. A Blackwell MIG 48GB slice has 48GB VRAM,
not the parent card's 96GB. Confirm model+KV cache fit, startup health, and
long-context generation in RunPod logs before treating 260K as verified.

When deploying, check for:
1. A successful Docker build and image push.
2. `llama-server is READY.` in worker logs, with the expected GPU detected.
3. A short SillyTavern response, followed by a long-context test.
4. No CUDA architecture or out-of-memory errors.

If this build fails, inspect the RunPod Build logs for the first CMake/NVCC
error; the earlier A40-only Dockerfile remains available in Git history.
