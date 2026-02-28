#!/bin/bash
set -euo pipefail

WORKSPACE="/workspace"
FORGE_DIR="$WORKSPACE/stable-diffusion-webui-forge"
MODELS_DIR="$FORGE_DIR/models"
PROVISIONING_FLAG="/.provisioning"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

download_model() {
    local url="$1" dest="$2" auth_type="${3:-}"
    mkdir -p "$(dirname "$dest")"

    local full_url="$url"
    if [[ "$auth_type" == "civitai" ]] && [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        if [[ "$url" == *\?* ]]; then
            full_url="${url}&token=${CIVITAI_TOKEN}"
        else
            full_url="${url}?token=${CIVITAI_TOKEN}"
        fi
    fi

    if [[ -f "$dest" ]] && [[ $(stat -c %s "$dest" 2>/dev/null || echo 0) -gt 100000000 ]]; then
        log "✅ Zaten var: $dest"
        return 0
    fi

    local attempt=1
    while [ $attempt -le 8 ]; do
        log "İndiriliyor ($attempt/8): $dest"
        if wget --timeout=120 --continue --progress=dot:giga -O "$dest" "$full_url"; then
            log "✅ Başarılı: $dest"
            return 0
        fi
        sleep 5
        ((attempt++))
    done
    log "❌ Başarısız: $dest"
    return 1
}

main() {
    log "🚀 Provisioning başladı..."

    local exts=(
        "https://github.com/wkpark/uddetailer"
        "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
        "https://github.com/Mikubill/sd-webui-controlnet"
        "https://github.com/Haoming02/sd-forge-ic-light"
        "https://github.com/zeittresor/sd-forge-fum"
        "https://github.com/jessearodriguez/sd-forge-regional-prompter"
        "https://github.com/Gourieff/sd-webui-reactor"
    )

    for ext in "${exts[@]}"; do
        local name=$(basename "$ext")
        if [[ ! -d "$FORGE_DIR/extensions/$name" ]]; then
            git clone "$ext" "$FORGE_DIR/extensions/$name" 2>/dev/null && log "✅ $name kuruldu" || log "⚠️ $name clone edilemedi"
        else
            log "✅ Zaten var: $name"
        fi
    done

    log "Modeller indiriliyor..."
    download_model "https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors" "$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors" &
    download_model "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor" "$MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors" "civitai" &
    download_model "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16" "$MODELS_DIR/Lora/femboy.safetensors" "civitai" &

    wait

    log "✅ Tüm modeller hazır! Provisioning tamamlandı."
    rm -f "$PROVISIONING_FLAG"
    supervisorctl restart forge
    log "🎉 WebUI kullanıma hazır!"
}

main
