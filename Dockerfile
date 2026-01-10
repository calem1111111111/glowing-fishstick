# ==================================================================
# VIDEO ENDPOINT - FINAL VERSION
# Uses extra_model_paths.yaml for correct model paths
# ==================================================================
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv and create venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

WORKDIR /comfyui

# ==========================================
# Install VIDEO-specific custom nodes
# ==========================================

# ComfyUI-WanVideoWrapper (main nodes for video generation)
RUN cd /comfyui/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    cd ComfyUI-WanVideoWrapper && \
    pip install -r requirements.txt --no-cache-dir || true

# ComfyUI-GGUF (for GGUF models if needed)
RUN cd /comfyui/custom_nodes && \
    git clone https://github.com/city96/ComfyUI-GGUF.git && \
    cd ComfyUI-GGUF && \
    pip install -r requirements.txt --no-cache-dir || true

# Wan2.2 FirstLastFrame support
RUN cd /comfyui/custom_nodes && \
    git clone https://github.com/stduhpf/ComfyUI--Wan22FirstLastFrameToVideoLatent.git || true

# Sage Attention (for faster generation)
RUN pip install sageattention --no-cache-dir || true

# ==========================================
# ADD EXTRA MODEL PATHS CONFIG
# This tells ComfyUI where to find models on Network Volume
# ==========================================
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml

# ==========================================
# Go back to root and install handler dependencies
# ==========================================
WORKDIR /

RUN uv pip install runpod requests websocket-client

# ==========================================
# Add workflows, handler, scripts
# ==========================================
RUN mkdir -p /comfyui/workflows

COPY workflows/ /comfyui/workflows/
COPY handler.py /handler.py
COPY test_input.json /test_input.json

# Copy startup script
COPY src/start.sh /start.sh
RUN chmod +x /start.sh

# Copy helper scripts
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

ENV PIP_NO_INPUT=1

# ==========================================
# Start: ComfyUI server first, then handler
# ==========================================
CMD ["/start.sh"]
