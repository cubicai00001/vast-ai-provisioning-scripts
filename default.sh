#!/bin/bash
set -euo pipefail

echo "=== Femboy Domination Optimized Provisioning (Fixed v2) ==="

# === CRITICAL: Activate Vast.ai Forge venv (fixes the uv error) ===
if [[ -f /venv/main/bin/activate ]]; then
    source /venv/main/bin/activate
    echo "✓ Activated /venv/main virtual environment"
else
    echo "⚠️  Venv not found - falling back to --system"
    SYSTEM_FLAG="--system"
fi

uv pip install ${SYSTEM_FLAG:-} --upgrade setuptools wheel packaging

WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"

mkdir -p "${MODELS_DIR}/Stable-diffusion" "${MODELS_DIR}/Lora" "${MODELS_DIR}/iclight"

# === Stable extensions only (removed broken ones: uddetailer, regional-prompter, faceswaplab) ===
EXTENSIONS=(
    "https://github.com/Bing-su/adetailer"
    "https://github.com/Mikubill/sd-webui-controlnet"
    "https://github.com/Haoming02/sd-forge-ic-light"
    "https://github.com/zeittresor/sd-forge-fum"
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
)

log() { echo "[$(date '+%H:%M:%S')] $*"; }

install_extensions() {
    log "Installing extensions..."
    mkdir -p "${FORGE_DIR}/extensions"
    cd "${FORGE_DIR}/extensions"

    for repo in "${EXTENSIONS[@]}"; do
        name=$(basename "$repo")
        if [ -d "$name" ]; then
            log "Updating $name"
            (cd "$name" && git pull --quiet) || true
        else
            log "Cloning $name"
            git clone --depth 1 --quiet "$repo" "$name" || log "Failed $name"
        fi
    done
}

download_models() {
    log "Downloading Juggernaut XL Ragnarok + femboy LoRAs + IC-Light..."

    # Main checkpoint (best for photoreal femboy)
    wget -q --show-progress --continue -O "${MODELS_DIR}/Stable-diffusion/juggernautXL_ragnarok.safetensors" \
        "https://civitai.com/api/download/models/1759168?type=Model&format=SafeTensor&size=full&fp=fp16" \
        && log "✓ juggernautXL_ragnarok.safetensors"

    # Your femboy LoRAs
    wget -q --show-progress --continue -O "${MODELS_DIR}/Lora/femboy_otoko_no_ko.safetensors" \
        "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor" \
        && log "✓ femboy_otoko_no_ko"

    wget -q --show-progress --continue -O "${MODELS_DIR}/Lora/femboy_v1.safetensors" \
        "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16" \
        && log "✓ femboy_v1"

    wget -q --show-progress --continue -O "${MODELS_DIR}/Lora/femboi_full_v1.safetensors" \
        "https://civitai.com/api/download/models/20797?type=Model&format=SafeTensor" \
        && log "✓ femboi_full_v1"

    wget -q --show-progress --continue -O "${MODELS_DIR}/Lora/femboysxl_v1.safetensors" \
        "https://civitai.com/api/download/models/324974?type=Model&format=SafeTensor" \
        && log "✓ femboysxl_v1"

    # IC-Light (excellent for dramatic lighting in domination scenes)
    wget -q --show-progress --continue -O "${MODELS_DIR}/iclight/iclight_sd15_fc.safetensors" \
        "https://huggingface.co/lllyasviel/iclight_v2/resolve/main/iclight_sd15_fc.safetensors" \
        && log "✓ IC-Light fc"

    wget -q --show-progress --continue -O "${MODELS_DIR}/iclight/iclight_sd15_fbc.safetensors" \
        "https://huggingface.co/lllyasviel/iclight_v2/resolve/main/iclight_sd15_fbc.safetensors" \
        && log "✓ IC-Light fbc"
}

main() {
    touch /.provisioning
    install_extensions
    download_models
    log "✅ PROVISIONING COMPLETED SUCCESSFULLY!"
    log "Recommended checkpoint: juggernautXL_ragnarok.safetensors"
    log "Best prompt starter: photorealistic raw photo of a beautiful delicate femboy crossdresser, detailed skin texture, natural lighting, submissive pose, bound and dominated by massive hyper-muscled male humanoid, sweat, cinematic angle, masterpiece, best quality"
    rm -f /.provisioning
}

main
