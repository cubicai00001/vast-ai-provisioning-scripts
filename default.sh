#!/bin/bash
set -euo pipefail

WORKSPACE="/workspace"
FORGE_DIR="$WORKSPACE/stable-diffusion-webui-forge"
MODELS_DIR="$FORGE_DIR/models"
PROVISIONING_FLAG="/.provisioning"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2; }

download_model() {
    local url="$1" dest="$2" auth_type="${3:-}" retry=0 max=8

    mkdir -p "$(dirname "$dest")"

    local full_url="$url"
    if [[ "$auth_type" == "civitai" ]] && [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        if [[ "$url" == *\?* ]]; then
            full_url="${url}&token=${CIVITAI_TOKEN}"
        else
            full_url="${url}?token=${CIVITAI_TOKEN}"
        fi
    fi

    if [[ -f "$dest" ]]; then
        local size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
        if (( size > 500000000 )); then
            log "✅ Zaten var: $dest"
            return 0
        fi
    fi

    while (( retry < max )); do
        ((retry++))
        log "İndiriliyor ($retry/$max): $dest"
        if wget --tries=1 --timeout=180 --continue --progress=dot:giga -O "$dest" "$full_url"; then
            log "✅ Başarılı: $dest"
            return 0
        fi
        sleep $((retry * 4))
    done
    log "❌ İndirilemedi: $dest"
    return 1
}

main() {
    log "🚀 Provisioning başladı..."

    # Extension'lar
    local exts=(
        "https://github.com/wkpark/uddetailer"
        "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
        "https://github.com/Mikubill/sd-webui-controlnet"
        "https://github.com/Haoming02/sd-forge-ic-light"
        "https://github.com/zeittresor/sd-forge-fum"
        "https://github.com/jessearodriguez/sd-forge-regional-prompter"
        "https://github.com/Gourieff/sd-webui-reactor"
    )

    for url in "${exts[@]}"; do
        local name=$(basename "$url")
        local target="$FORGE_DIR/extensions/$name"
        if [[ ! -d "$target" ]]; then
            git clone --depth 1 "$url" "$target" 2>/dev/null && log "✅ $name kuruldu" || log "⚠️ $name clone edilemedi"
        else
            log "✅ Zaten var: $name"
        fi
    done

    # Modeller
    log "Modeller indiriliyor..."

    download_model \
        "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16" \
        "$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors" "civitai"

    download_model \
        "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor" \
        "$MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors" "civitai"

    download_model \
        "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16" \
        "$MODELS_DIR/Lora/femboy.safetensors" "civitai"

    log "✅ Tüm modeller hazır! Provisioning tamamlandı."
    rm -f "$PROVISIONING_FLAG" 2>/dev/null || true
    supervisorctl restart forge 2>/dev/null || true

    log "🎉 WebUI kullanıma hazır!"
}

main
