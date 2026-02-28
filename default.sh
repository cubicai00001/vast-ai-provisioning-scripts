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

    # zaten tam boyutta varsa atla
    if [[ -f "$dest" ]]; then
        local size
        size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
        if (( size > 500000000 )); then     # ~500 MB'den büyükse tamam kabul et
            log "Zaten var (yeterli boyutta): $dest"
            return 0
        fi
    fi

    while (( retry < max )); do
        ((retry++))
        log "İndiriliyor ($retry/$max): $dest"
        if wget --tries=1 --timeout=180 --continue --progress=dot:giga \
                -O "$dest" "$full_url"; then
            log "Başarılı: $dest"
            return 0
        fi
        log "Başarısız, ${retry}. deneme..."
        sleep $((retry * 3 + 2))
    done

    log "❌ İndirme başarısız kaldı: $dest"
    return 1
}

main() {
    log "Provisioning başladı..."

    # ────────────────────────────────────────────────
    # Extension'lar (FaceswapLab yerine Reactor + çalışanlar)
    # ────────────────────────────────────────────────
    local extensions=(
        "https://github.com/wkpark/uddetailer"
        "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
        "https://github.com/Mikubill/sd-webui-controlnet"
        "https://github.com/Haoming02/sd-forge-ic-light"
        "https://github.com/zeittresor/sd-forge-fum"
        "https://github.com/jessearodriguez/sd-forge-regional-prompter"
        "https://github.com/Gourieff/sd-webui-reactor"
    )

    for url in "${extensions[@]}"; do
        local name
        name=$(basename "$url" .git)
        local target="$FORGE_DIR/extensions/$name"

        if [[ -d "$target" ]]; then
            log "Zaten var → $name"
        else
            log "Kuruluyor → $name"
            git clone --depth 1 "$url" "$target" 2>/dev/null && \
                log "Başarılı → $name" || \
                log "Clone başarısız → $name (devam ediliyor)"
        fi
    done

    # ────────────────────────────────────────────────
    # Modeller
    # Pony için en güncel ve çalışan HF mirror'lar (2026 başı)
    # ────────────────────────────────────────────────
    log "Modeller indiriliyor..."

    # Pony Diffusion V6 XL – en güvenilir mirror'lar (sırayla dene)
    local pony_urls=(
        "https://huggingface.co/AI-Model-Host/pony-diffusion-v6-xl/resolve/main/ponyDiffusionV6XL.safetensors"
        "https://huggingface.co/John6666/pony-diffusion-v6-xl/resolve/main/ponyDiffusionV6XL.safetensors"
        "https://huggingface.co/6chan/Pony-Diffusion-V6-XL/resolve/main/ponyDiffusionV6XL_v6StartWithThisOne.safetensors"
    )

    local pony_dest="$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"
    local pony_ok=0

    for url in "${pony_urls[@]}"; do
        if download_model "$url" "$pony_dest"; then
            pony_ok=1
            break
        fi
    done

    if (( pony_ok == 0 )); then
        log "UYARI: Pony hiçbir mirror'dan inemedi! Manuel indirmeniz gerekebilir."
    fi

    # LoRA'lar (CivitAI)
    download_model \
        "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor" \
        "$MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors" "civitai"

    download_model \
        "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16" \
        "$MODELS_DIR/Lora/femboy.safetensors" "civitai"

    # ────────────────────────────────────────────────
    # Provisioning tamam → Forge'u başlat
    # ────────────────────────────────────────────────
    log "Provisioning tamamlandı."
    rm -f "$PROVISIONING_FLAG" 2>/dev/null || true
    supervisorctl restart forge 2>/dev/null || log "supervisorctl restart forge başarısız"

    log "WebUI artık kullanıma hazır olmalı."
}

main
