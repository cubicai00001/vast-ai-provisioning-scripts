#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-3}"

### Photorealistic Crossdresser / Femboy Setup (Grok Imagine quality) ###
CIVITAI_MODELS_DEFAULT=(
    # Juggernaut XL Ragnarok - best photoreal SDXL base 2026
    "https://civitai.com/api/download/models/1759168?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Stable-diffusion/juggernautXL_ragnarok.safetensors"

    # Juggernaut Cinematic XL LoRA - cinematic realism, perfect skin & lighting
    "https://civitai.com/api/download/models/131991?type=Model&format=SafeTensor | $MODELS_DIR/Lora/juggernaut_cinematic_xl.safetensors"

    # Best realistic femboy / crossdresser LoRAs for Juggernaut
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy_v1.safetensors"
    "https://civitai.com/api/download/models/20797?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboi_full_v1.safetensors"
    "https://civitai.com/api/download/models/324974?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Flux.1 Dev (FP8) - uncomment to enable (needs HF_TOKEN for gated access)
    # "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors | $MODELS_DIR/Unet/flux1-dev-fp8.safetensors"
    # "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors | $MODELS_DIR/VAE/ae.safetensors"
    # "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors | $MODELS_DIR/Clip/clip_l.safetensors"
    # "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors | $MODELS_DIR/Clip/t5xxl_fp8_e4m3fn.safetensors"
)

EXTENSIONS=(
    "https://github.com/Bing-su/adetailer"
    "https://github.com/Mikubill/sd-webui-controlnet"
    "https://github.com/wkpark/uddetailer"
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
    "https://github.com/Ethereum-John/sd-webui-forge-faceswaplab"
    "https://github.com/Haoming02/sd-forge-ic-light"
    "https://github.com/zeittresor/sd-forge-fum"
    "https://github.com/jessearodriguez/sd-forge-regional-prompter"
)

### End Configuration ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

script_cleanup() {
    log "Cleaning up..."
    rm -rf "$SEMAPHORE_DIR" 2>/dev/null || true
    rm -f /.provisioning
}

trap script_cleanup EXIT
trap 'log "Error on line $LINENO"; exit 1' ERR

download_file() {
    local url="$1"
    local output_path="$2"
    local max_retries=12
    local retry=0

    local output_dir="$(dirname "$output_path")"
    local output_file="$(basename "$output_path")"
    mkdir -p "$output_dir"

    if [[ -f "$output_path" && -s "$output_path" ]]; then
        log "Already exists: $output_file (skipping)"
        return 0
    fi

    while [ $retry -lt $max_retries ]; do
        log "Downloading ($((retry+1))/$max_retries): $output_file"

        local wget_cmd=(wget --timeout=90 --tries=1 --continue --progress=dot:giga \
            --user-agent="Mozilla/5.0" --no-check-certificate)

        # FIXED AUTH LOGIC - this solves the 400 Bad Request
        if [[ -n "${HF_TOKEN:-}" && "$url" == *huggingface.co* ]]; then
            wget_cmd+=(--header="Authorization: Bearer $HF_TOKEN")
        elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" == *civitai.com* ]]; then
            wget_cmd+=(--header="Authorization: Bearer $CIVITAI_TOKEN")
            # NO ?token= append (prevents R2 400 errors)
        fi

        if "${wget_cmd[@]}" -O "$output_path.tmp" "$url"; then
            mv "$output_path.tmp" "$output_path"
            log "✓ Success: $output_file"
            return 0
        fi

        rm -f "$output_path.tmp"
        retry=$((retry + 1))
        sleep $((retry * 10))
    done

    log "✗ Failed after $max_retries attempts: $output_file"
    return 1
}

install_extensions() {
    log "Installing ${#EXTENSIONS[@]} extensions..."
    local ext_dir="${FORGE_DIR}/extensions"
    mkdir -p "$ext_dir"

    for repo in "${EXTENSIONS[@]}"; do
        local name=$(basename "$repo" .git)
        local target="$ext_dir/$name"

        if [[ -d "$target/.git" ]]; then
            log "Updating $name"
            (cd "$target" && git pull --quiet --ff-only || true)
        else
            log "Cloning $name"
            git clone --depth 1 --quiet "$repo" "$target" || log "Failed to clone $name"
        fi
    done
}

install_models() {
    log "Downloading models (Juggernaut XL + photoreal femboy LoRAs + optional Flux.1 Dev)..."
    mkdir -p "$SEMAPHORE_DIR"

    for entry in "${CIVITAI_MODELS_DEFAULT[@]}"; do
        IFS='|' read -r url path <<< "$entry"
        url=$(echo "$url" | xargs)
        path=$(echo "$path" | xargs)
        if [[ -n "$url" && -n "$path" ]]; then
            download_file "$url" "$path" &
        fi
    done
    wait
}

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_extensions
    install_models

    log "✅ Provisioning completed!"
    log "To use Flux.1 Dev: In Forge UI, select 'flux1-dev-fp8' as checkpoint. Prompt tip: 'photorealistic raw photo of a beautiful crossdresser male, detailed skin, natural lighting' --no 'cartoon, anime'"
}

main
