#!/bin/bash
set -e

# Entrypoint script for ComfyUI Video Endpoint
# Creates symlinks from Network Volume to ComfyUI models directory

VOLUME_ROOT="${VOLUME_ROOT:-/workspace}"
COMFYUI_DIR="/comfyui"
COMFYUI_MODELS_DIR="${COMFYUI_DIR}/models"
VOLUME_MODELS_DIR="${VOLUME_ROOT}/models"

echo "=========================================="
echo "ComfyUI Video Endpoint - Entrypoint"
echo "=========================================="
echo "Volume Root: ${VOLUME_ROOT}"
echo "ComfyUI Dir: ${COMFYUI_DIR}"
echo "Volume Models: ${VOLUME_MODELS_DIR}"
echo ""

# Check if volume is mounted
if [ ! -d "${VOLUME_ROOT}" ]; then
    echo "ERROR: Volume root ${VOLUME_ROOT} not found!"
    echo "Make sure Network Volume is mounted at ${VOLUME_ROOT}"
    exit 1
fi

if [ ! -d "${VOLUME_MODELS_DIR}" ]; then
    echo "WARNING: Models directory ${VOLUME_MODELS_DIR} not found!"
    echo "Creating directory structure..."
    mkdir -p "${VOLUME_MODELS_DIR}"/{checkpoints,vae,clip,text_encoders,diffusion_models,loras,controlnet,upscale_models,bbox,ipadapter}
fi

# Create ComfyUI models directory structure if it doesn't exist
mkdir -p "${COMFYUI_MODELS_DIR}"

# Create symlinks for each model type
echo "Creating symlinks from volume to ComfyUI models directory..."

MODEL_TYPES=(
    "checkpoints"
    "vae"
    "clip"
    "text_encoders"
    "diffusion_models"
    "loras"
    "controlnet"
    "upscale_models"
    "bbox"
    "ipadapter"
)

for model_type in "${MODEL_TYPES[@]}"; do
    volume_path="${VOLUME_MODELS_DIR}/${model_type}"
    comfyui_path="${COMFYUI_MODELS_DIR}/${model_type}"
    
    if [ -d "${volume_path}" ] && [ "$(ls -A ${volume_path} 2>/dev/null)" ]; then
        # Remove existing directory/link if it exists
        if [ -e "${comfyui_path}" ]; then
            rm -rf "${comfyui_path}"
        fi
        
        # Create symlink
        ln -sf "${volume_path}" "${comfyui_path}"
        echo "  ✓ Linked ${model_type} -> ${volume_path}"
    else
        # Create empty directory if volume path doesn't exist
        mkdir -p "${comfyui_path}"
        echo "  ⚠ ${model_type} not found in volume, created empty directory"
    fi
done

echo ""
echo "Symlinks created successfully!"
echo ""

# Verify critical models exist (optional - can be removed for production)
echo "Checking for critical models..."
CRITICAL_MODELS=(
    "diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors"
    "vae/wan_2.1_vae.safetensors"
    "text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
)

MISSING_MODELS=0
for model in "${CRITICAL_MODELS[@]}"; do
    if [ ! -f "${VOLUME_MODELS_DIR}/${model}" ]; then
        echo "  ⚠ WARNING: ${model} not found in volume"
        MISSING_MODELS=$((MISSING_MODELS + 1))
    else
        echo "  ✓ Found ${model}"
    fi
done

if [ ${MISSING_MODELS} -gt 0 ]; then
    echo ""
    echo "WARNING: Some critical models are missing!"
    echo "Please ensure all models are downloaded to the Network Volume."
    echo "See volumes/models/scripts/populate_volume.sh for download instructions."
fi

echo ""
echo "Starting ComfyUI handler..."
echo ""

# Execute the command passed to entrypoint
exec "$@"

