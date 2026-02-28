#!/bin/bash
set -e

echo "=== Pony Diffusion XL Provisioning v2.2 (Simplified) ==="

WORKSPACE="${WORKSPACE:-/workspace}"
FORGE_DIR="$WORKSPACE/stable-diffusion-webui-forge"
MODELS_DIR="$FORGE_DIR/models"

mkdir -p "$MODELS_DIR/Stable-diffusion" "$MODELS_DIR/Lora" "$MODELS_DIR/VAE"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# === ONLY PONYXL COMPATIBLE MODELS ===
log "Downloading base model + XL LoRAs..."

# Pony Diffusion V6 XL (base)
if [ ! -s "$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors" ]; then
    log "→ ponyDiffusionV6XL.safetensors"
    wget -q --show-progress --continue \
        https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors \
        -O "$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"
fi

# XL LoRAs (all confirmed Pony-compatible)
for url in \
    "https://civitai.com/api/download/models/324974 | femboysxl_v1.safetensors" \
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor | male_mix_pony.safetensors" \
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | curvy_femboy_xl.safetensors"; do

    IFS='|' read -r url path <<< "$url"
    filename=$(echo "$path" | xargs)
    if [ ! -s "$MODELS_DIR/Lora/$filename" ]; then
        log "→ $filename"
        if [[ "$url" == *huggingface.co* && -n "${HF_TOKEN:-}" ]]; then
            wget --header="Authorization: Bearer $HF_TOKEN" --continue "$url" -O "$MODELS_DIR/Lora/$filename"
        else
            wget --continue "$url" -O "$MODELS_DIR/Lora/$filename"
        fi
    fi
done

# Extensions (optional but useful)
log "Installing extensions..."
cd "$FORGE_DIR/extensions" || mkdir -p "$FORGE_DIR/extensions" && cd "$FORGE_DIR/extensions"
for repo in \
    "https://github.com/Mikubill/sd-webui-controlnet" \
    "https://github.com/Bing-su/adetailer" \
    "https://github.com/wkpark/uddetailer" \
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"; do
    name=$(basename "$repo")
    if [ ! -d "$name" ]; then
        git clone --depth 1 "$repo" "$name" &>/dev/null && log "  ✓ $name"
    else
        (cd "$name" && git pull --quiet) &>/dev/null && log "  ✓ $name (updated)"
    fi
done

log "✅ Provisioning finished successfully!"
log "You now have Pony Diffusion V6 XL + 3 high-quality femboy XL LoRAs"
rm -f /.provisioning
