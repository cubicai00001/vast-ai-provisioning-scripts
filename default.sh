#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"

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

CIVITAI_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL (Civitai + reliable HF mirror)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy LoRAs
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Fallback alternatives (same job)
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor | $MODELS_DIR/Lora/male_mix_pony.safetensors"
    "https://civitai.com/api/download/models/1861600?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_pony.safetensors"
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | $MODELS_DIR/Lora/curvy_femboy_xl.safetensors"
)

### End Configuration ###

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

normalize_entry() {
    echo "$1" | tr -d '\n\r' | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

download_file() {
    local raw_urls="$1" dest="$2"
    IFS=' ' read -ra sources <<< "$raw_urls"

    local out_dir="$(dirname "$dest")"
    mkdir -p "$out_dir"

    if [[ -f "$dest" && -s "$dest" ]]; then
        log "Already exists: $(basename "$dest")"
        return 0
    fi

    log "Downloading $(basename "$dest")"
    [[ -n "${CIVITAI_TOKEN:-}" ]] && log "  CIVITAI_TOKEN detected"

    local auth_header="" token_query=""
    if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        auth_header="Authorization: Bearer $CIVITAI_TOKEN"
        token_query="token=$CIVITAI_TOKEN"
    fi

    for url_base in "${sources[@]}"; do
        local url="$url_base"
        if [[ $url_base == *civitai* ]]; then
            if [[ $url_base == *\?* ]]; then
                url="${url_base}&${token_query}"
            else
                url="${url_base}?${token_query}"
            fi
        fi

        log "  Trying: $url"

        if curl -L --fail --retry 2 --retry-delay 3 \
            --connect-timeout 60 --max-time 900 \
            ${auth_header:+-H "$auth_header"} \
            -A "Mozilla/5.0" --no-progress-meter \
            -o "$dest.tmp" "$url"; then
            mv "$dest.tmp" "$dest"
            log "SUCCESS: $(basename "$dest")"
            return 0
        fi

        log "  Failed, trying next source..."
        sleep 2
    done

    log "FAILED all sources for $(basename "$dest")"
    rm -f "$dest.tmp"
    return 1
}

install_models() {
    local -a models=()
    # Support CIVITAI_MODELS env override if you want
    while IFS= read -r -d '' m; do [[ -n "$m" ]] && models+=("$m"); done < <(parse_env_array "CIVITAI_MODELS")
    [[ ${#models[@]} -eq 0 ]] && models=("${CIVITAI_MODELS_DEFAULT[@]}")

    log "Starting ${#models[@]} model downloads..."

    for entry in "${models[@]}"; do
        IFS='|' read -r urls dest <<< "$entry"
        urls=$(normalize_entry "$urls")
        dest=$(normalize_entry "$dest")
        [[ -z "$urls" || -z "$dest" ]] && continue

        if download_file "$urls" "$dest"; then
            log "Model ready: $(basename "$dest")"
        else
            log "Skipped: $(basename "$dest")"
        fi
    done
}

parse_env_array() {
    local var="$1"
    local value="${!var:-}"
    [[ -z "$value" ]] && return
    local -a arr=()
    IFS=';' read -ra parts <<< "$value"
    for p in "${parts[@]}"; do
        p=$(normalize_entry "$p")
        [[ -z "$p" || "$p" == \#* ]] && continue
        arr+=("$p")
    done
    printf '%s\0' "${arr[@]}"
}

main() {
    touch /.provisioning
    install_models
    rm -f /.provisioning
    log "Provisioning finished."
}

main
