# ==================================================================
# VIDEO ENDPOINT - Based on glowing-fishstick (WORKING)
# ==================================================================
ARG BASE_IMAGE=nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=false
ARG PYTORCH_INDEX_URL

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
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

# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch torchvision torchaudio --index-url ${PYTORCH_INDEX_URL}; \
    fi

# Change working directory to ComfyUI
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
# SYMLINK IMPLEMENTATION FOR VIDEO MODELS
# ==========================================

# Clean out the empty model directories that ComfyUI installs
RUN rm -rf /comfyui/models/loras \
           /comfyui/models/vae \
           /comfyui/models/diffusion_models \
           /comfyui/models/text_encoders \
           /comfyui/models/clip \
           /comfyui/models/checkpoints

# Create symbolic links to the Network Volume mount point (/runpod-volume)
# This fools ComfyUI into thinking the models are local.

# Checkpoints (SDXL/SD models)
RUN ln -s /runpod-volume/models/checkpoints /comfyui/models/checkpoints

# LoRAs
RUN ln -s /runpod-volume/loras /comfyui/models/loras

# VAEs
RUN ln -s /runpod-volume/vae /comfyui/models/vae

# UNETs / Diffusion Models
RUN ln -s /runpod-volume/diffusion_models /comfyui/models/diffusion_models

# CLIP / Text Encoders  
RUN ln -s /runpod-volume/text_encoders /comfyui/models/text_encoders

# Alternative CLIP path
RUN ln -s /runpod-volume/clip /comfyui/models/clip

# ==========================================
# Install Python runtime dependencies for the handler
# ==========================================
WORKDIR /
RUN uv pip install runpod requests websocket-client

# ==========================================
# Add workflows and handler
# ==========================================
RUN mkdir -p /comfyui/workflows
COPY workflows/ /comfyui/workflows/
COPY handler.py /handler.py
COPY test_input.json /test_input.json

# Copy startup script
COPY src/start.sh /start.sh
RUN chmod +x /start.sh

# Copy scripts directory for comfy-manager
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# ==========================================
# Set the default command to run when starting the container
# ==========================================
# Use start.sh which starts ComfyUI server first, then handler
CMD ["/start.sh"]

