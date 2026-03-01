#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-2}"

# Early venv setup for build tools (fixes mmcv-style errors)
uv pip install --upgrade "setuptools>=70" wheel packaging

APT_PACKAGES=()
PIP_PACKAGES=()

# Removed: uddetailer (breaks Forge), faceswaplab (git issues), regional-prompter (sd_hijack error)
# Kept: ADetailer, ControlNet, IC-Light, ultimate-upscale, fum (all stable)
EXTENSIONS=(
    "https://github.com/Bing-su/adetailer"
    "https://github.com/Mikubill/sd-webui-controlnet"
    "https://github.com/Haoming02/sd-forge-ic-light"
    "https://github.com/zeittresor/sd-forge-fum"
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
)

# Your original femboy models + Juggernaut (kept)
# Added: muscular dominant male LoRA example (change URL if you prefer another)
CIVITAI_MODELS_DEFAULT=(
    "https://civitai.com/api/download/models/1759168?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Stable-diffusion/juggernautXL_ragnarok.safetensors"
    "https://civitai.com/api/download/models/131991?type=Model&format=SafeTensor | $MODELS_DIR/Lora/juggernaut_cinematic_xl.safetensors"
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy_v1.safetensors"
    "https://civitai.com/api/download/models/20797?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboi_full_v1.safetensors"
    "https://civitai.com/api/download/models/324974?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboysxl_v1.safetensors"
    # Muscular dominant male (example - replace with your favorite)
    "https://civitai.com/api/download/models/123456?type=Model&format=SafeTensor | $MODELS_DIR/Lora/muscular_dominant_male.safetensors"  # ← change this ID
)

WGET_DOWNLOADS_DEFAULT=(
    # IC-Light models (required by the extension)
    "https://huggingface.co/lllyasviel/iclight_v2/resolve/main/iclight_sd15_fc.safetensors $MODELS_DIR/iclight/iclight_sd15_fc.safetensors"
    "https://huggingface.co/lllyasviel/iclight_v2/resolve/main/iclight_sd15_fbc.safetensors $MODELS_DIR/iclight/iclight_sd15_fbc.safetensors"
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

script_cleanup() {
    rm -rf "$SEMAPHORE_DIR" 2>/dev/null || true
    rm -f /.provisioning
}

trap script_cleanup EXIT

# (download_file, acquire_slot, etc. functions unchanged from original - kept for brevity; copy them from the raw script you had)

install_extensions() {
    log "Installing extensions (stable set for Forge Neo)..."
    export GIT_TERMINAL_PROMPT=0  # prevents username prompt
    export GIT_CONFIG_GLOBAL=/tmp/gitconfig-safe
    echo -e "[safe]\n    directory = *" > "$GIT_CONFIG_GLOBAL"

    local ext_dir="${FORGE_DIR}/extensions"
    mkdir -p "$ext_dir"

    for repo_url in "${EXTENSIONS[@]}"; do
        local repo_name=$(basename "$repo_url" .git)
        local target_dir="$ext_dir/$repo_name"
        if [[ -d "$target_dir/.git" ]]; then
            (cd "$target_dir" && git pull --quiet) || log "[WARN] Update failed: $repo_name"
        else
            git clone --quiet --depth 1 "$repo_url" "$target_dir" || log "[WARN] Clone failed: $repo_name"
        fi
    done
}

# install_civitai_models and install_wget_downloads functions (same as original, but now WGET_DOWNLOADS_DEFAULT is populated)

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_apt_packages
    install_pip_packages
    install_extensions
    install_civitai_models
    install_wget_downloads

    log "✅ Provisioning completed successfully!"
    log "Your setup is optimized for photoreal femboy/crossdresser domination porn."
    log "Recommended prompt: photorealistic raw photo of a beautiful delicate femboy crossdresser, detailed skin, natural lighting, submissive, bound, dominated by huge hyper-muscled male (or anthro beast), sweat, dynamic angle, masterpiece"
    log "Use ADetailer + ControlNet OpenPose for perfect anatomy in domination scenes."
    log "IC-Light models installed for advanced relighting."
}

main
