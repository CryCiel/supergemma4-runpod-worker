
# Build tested llama.cpp version for A40
FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build build-essential \
    libcurl4-openssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# CUDA stub for Docker builds without a GPU driver
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so \
    /usr/local/cuda/lib64/stubs/libcuda.so.1

RUN git clone https://github.com/ggml-org/llama.cpp.git \
    && cd llama.cpp \
    && git checkout 0a1ef309c \
    && cmake -S . -B build -G Ninja \
       -DCMAKE_BUILD_TYPE=Release \
       -DGGML_CUDA=ON \
       -DCMAKE_CUDA_ARCHITECTURES=86 \
       -DLLAMA_CURL=ON \
       -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,/usr/local/cuda/lib64/stubs -L/usr/local/cuda/lib64/stubs -lcuda" \
       -DCMAKE_SHARED_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs -lcuda" \
    && cmake --build build --parallel 8 --target llama-server


# RunPod Serverless runtime
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV LD_LIBRARY_PATH=/app

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    bash curl ca-certificates libcurl4 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Copy the tested llama.cpp binaries and libraries
COPY --from=builder /opt/llama.cpp/build/bin/ /app/

# Keep the existing RunPod worker code
COPY ./src/ /work/

RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt \
    && chmod +x /work/start.sh

ENV PATH="/opt/venv/bin:${PATH}"

ENTRYPOINT ["/bin/bash", "/work/start.sh"]
