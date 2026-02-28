#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-1}"

APT_PACKAGES=()
PIP_PACKAGES=()

EXTENSIONS=(
    "https://github.com/wkpark/uddetailer"
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
    "https://github.com/Mikubill/sd-webui-controlnet"
    "https://github.com/Ethereum-John/sd-webui-forge-faceswaplab"
    "https://github.com/Haoming02/sd-forge-ic-light"
    "https://github.com/zeittresor/sd-forge-fum"
    "https://github.com/jessearodriguez/sd-forge-regional-prompter"
    "https://github.com/Bing-su/adetailer"
)

HF_MODELS_DEFAULT=()

CIVITAI_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL (primary)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors https://tensor.art/models/717274695390638697 | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy (Otoko No Ko) v1.0 (primary + alt mirror if found, but none; fallback to similar)
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"

    # Femboy v1.0 (primary)
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"

    # Femboi Full v1.0 (primary)
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"

    # femboysXL v1.0 (primary)
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Alternatives (for femboy concepts if primaries fail)
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor https://huggingface.co/some_mirror_if_found | $MODELS_DIR/Lora/male_mix_pony.safetensors"  # Male Mix Pony
    "https://civitai.com/api/download/models/1861600?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_pony.safetensors"  # Femboy pony
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | $MODELS_DIR/Lora/curvy_femboy_xl.safetensors"  # CurvyFemboyXL (HF mirror)
)

### End Configuration ###

# [rest of script same as previous, but with fixed line 179]
download_file() {
    # ... [same as before]

    for url_base in "${sources[@]}"; do
        local url="$url_base"
        if [[ $url_base == *civitai* ]]; then
            url="${url_base}${token_query}"
        fi

        log "Trying source: $url"

        # ... [retry loop same]
    done

    # ... 
}

# [other functions same]

install_civitai_models() {
    # same, sequential
}

main() {
    # same
}

main
