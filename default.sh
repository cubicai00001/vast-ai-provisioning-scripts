#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"

CIVITAI_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL - Civitai + CORRECT HF mirror (this filename actually exists)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL_v6StartWithThisOne.safetensors | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy LoRAs (your original list)
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Fallback alternatives (same style)
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor | $MODELS_DIR/Lora/male_mix_pony.safetensors"
    "https://civitai.com/api/download/models/1861600?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_pony.safetensors"
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | $MODELS_DIR/Lora/curvy_femboy_xl.safetensors"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

download_file() {
    local raw_urls="$1" dest="$2"
    IFS=' ' read -ra sources <<< "$raw_urls"

    mkdir -p "$(dirname "$dest")"

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
        if [[ -n "$token_query" && $url_base == *civitai* ]]; then
            if [[ $url_base == *\?* ]]; then
                url="${url_base}&${token_query}"
            else
                url="${url_base}?${token_query}"
            fi
        fi

        log "  Trying: $url"

        if curl -L --fail --retry 3 --retry-delay 2 \
            --connect-timeout 30 --max-time 600 \
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

main() {
    touch /.provisioning
    for entry in "${CIVITAI_MODELS_DEFAULT[@]}"; do
        IFS='|' read -r urls dest <<< "$entry"
        urls=$(echo "$urls" | xargs)
        dest=$(echo "$dest" | xargs)
        [[ -z "$urls" || -z "$dest" ]] && continue
        download_file "$urls" "$dest" || true
    done
    rm -f /.provisioning
    log "Provisioning finished."
}

main
