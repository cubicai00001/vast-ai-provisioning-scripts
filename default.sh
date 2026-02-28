#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"

MAX_PARALLEL=3

# ────────────────────────────────────────────────
# EXTENSIONS (FaceswapLab öldüğü için yerine en iyi alternatif: Reactor)
# ────────────────────────────────────────────────
EXTENSIONS=(
    "https://github.com/wkpark/uddetailer"
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
    "https://github.com/Mikubill/sd-webui-controlnet"
    "https://github.com/Haoming02/sd-forge-ic-light"
    "https://github.com/zeittresor/sd-forge-fum"
    "https://github.com/jessearodriguez/sd-forge-regional-prompter"
    "https://github.com/Gourieff/sd-webui-reactor"          # ← En stabil face swap (FaceswapLab alternatifi)
)

# ────────────────────────────────────────────────
# MODELLER (CivitAI bağımlılığını minimuma indirdik)
# ────────────────────────────────────────────────
HF_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL - HF mirror (en stabil, CivitAI'ye hiç dokunmuyoruz)
    "https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors
    |$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"
)

CIVITAI_MODELS_DEFAULT=(
    # Femboy LoRA 1
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor
    |$MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors
    |civitai"

    # Femboy LoRA 2
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16
    |$MODELS_DIR/Lora/femboy.safetensors
    |civitai"
)

### Log Fonksiyonu ###
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

### Temizleme ###
script_cleanup() {
    rm -rf /tmp/download_sem_* 2>/dev/null || true
}

trap script_cleanup EXIT

### Yardımcı Fonksiyonlar (download_file - query token ile) ###
download_file() {
    local url="$1"
    local output_path="$2"
    local auth_type="${3:-}"
    local max_retries=8
    local retry_delay=4

    mkdir -p "$(dirname "$output_path")"

    local auth_param=""
    if [[ "$auth_type" == "civitai" ]] && [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        if [[ "$url" == *\?* ]]; then
            auth_param="&token=${CIVITAI_TOKEN}"
        else
            auth_param="?token=${CIVITAI_TOKEN}"
        fi
    fi

    local full_url="${url}${auth_param}"
    local lockfile="${output_path}.lock"

    (
        flock -x -w 600 200 || { log "Lock timeout: $output_path"; exit 1; }

        if [[ -f "$output_path" ]] && [[ $(stat -c %s "$output_path") -gt 1000000 ]]; then
            log "Zaten var (tam): $output_path"
            exit 0
        fi

        local attempt=1
        while [ $attempt -le $max_retries ]; do
            log "İndiriliyor ($attempt/$max_retries): $output_path"
            if wget --timeout=90 --continue --progress=dot:giga -O "$output_path" "$full_url" 2>&1; then
                log "✅ Başarıyla indirildi: $output_path"
                exit 0
            fi
            sleep $retry_delay
            attempt=$((attempt + 1))
        done
        log "❌ İndirme başarısız: $output_path"
        exit 1
    ) 200>"$lockfile"
    rm -f "$lockfile"
}

### Ana Fonksiyon ###
main() {
    log "🚀 Provisioning başladı..."

    # Extension'ları kur
    log "Extension'lar kuruluyor..."
    for ext in "${EXTENSIONS[@]}"; do
        local name=$(basename "$ext")
        if [[ -d "${FORGE_DIR}/extensions/$name" ]]; then
            log "Zaten var: $name (atlandı)"
        else
            git clone "$ext" "${FORGE_DIR}/extensions/$name" && log "✅ $name kuruldu" || log "⚠️ $name kurulamadı"
        fi
    done

    # Modelleri indir (HF + CivitAI)
    log "Modeller indiriliyor (Pony HF'den + LoRA'lar)..."
    for model in "${HF_MODELS_DEFAULT[@]}"; do
        IFS='|' read -r url dest <<< "$model"
        download_file "$url" "$dest" &
    done

    for model in "${CIVITAI_MODELS_DEFAULT[@]}"; do
        IFS='|' read -r url dest auth <<< "$model"
        download_file "$url" "$dest" "$auth" &
    done
    wait

    # ────────────────────────────────────────────────
    # ★★★ KRİTİK: İndirmeler bitince Forge'u aç ve "Open" butonunu aktif et ★★★
    # ────────────────────────────────────────────────
    log "✅ Tüm indirmeler tamamlandı. Forge başlatılıyor..."
    rm -f /.provisioning                    # Instance Portal "Open" butonunu serbest bırakır
    supervisorctl restart forge             # Forge'u başlat

    log "🎉 Provisioning TAMAMLANDI! Artık WebUI kullanıma hazır."
}

main
