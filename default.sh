#!/bin/bash
set -euo pipefail

### Configuration - Flux Photoreal NSFW (Full Features + bitsandbytes Fix) ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-2}"

APT_PACKAGES=()
PIP_PACKAGES=(
    "bitsandbytes>=0.43.0"          # ← This fixes the AssertionError for NF4 Flux
)

EXTENSIONS=(
    "https://github.com/Mikubill/sd-webui-controlnet"
    "https://github.com/Bing-su/adetailer"
    "https://github.com/Haoming02/sd-forge-ic-light"
    "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
    "https://github.com/wkpark/uddetailer"
)

CIVITAI_MODELS_DEFAULT=(
    # Main Flux model
    "https://huggingface.co/lllyasviel/flux1-dev-bnb-nf4/resolve/main/flux1-dev-bnb-nf4-v2.safetensors | $MODELS_DIR/Stable-diffusion/flux1-dev-bnb-nf4-v2.safetensors"

    # Required Text Encoders
    "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors | $MODELS_DIR/text_encoder/clip_l.safetensors"
    "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors | $MODELS_DIR/text_encoder/t5xxl_fp16.safetensors"

    # Flux VAE
    "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors | $MODELS_DIR/VAE/ae.safetensors"

    # Recommended LoRAs
    "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors | $MODELS_DIR/Lora/realism_lora.safetensors"
    "https://civitai.com/api/download/models/696714 | $MODELS_DIR/Lora/femboy_flux.safetensors"
)

### End Configuration ###

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

script_cleanup() {
    log "Cleaning up..."
    rm -rf "$SEMAPHORE_DIR"
    rm -f /.provisioning
}

script_error() {
    log "[ERROR] Provisioning failed at line $1 with code $?"
    exit 1
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

normalize_entry() {
    echo "$1" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//'
}

parse_env_array() {
    local env_var_name="$1"
    local env_value="${!env_var_name:-}"
    [[ -z "$env_value" ]] && return
    local -a result=()
    IFS=';' read -ra entries <<< "$env_value"
    for entry in "${entries[@]}"; do
        entry=$(normalize_entry "$entry")
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        result+=("$entry")
    done
    printf '%s\0' "${result[@]}"
}

merge_with_env() {
    local env_var_name="$1"
    shift
    local -a defaults=("$@")
    for entry in "${defaults[@]}"; do
        entry=$(normalize_entry "$entry")
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        printf '%s\0' "$entry"
    done
    parse_env_array "$env_var_name"
}

acquire_slot() {
    local prefix="$1"
    local max_slots="$2"
    local slot_dir="$(dirname "$prefix")"
    local slot_prefix="$(basename "$prefix")"
    while true; do
        local count=$(find "$slot_dir" -maxdepth 1 -name "${slot_prefix}_*" 2>/dev/null | wc -l)
        if [ "$count" -lt "$max_slots" ]; then
            local slot="${prefix}_$$_${RANDOM}_${RANDOM}"
            if (set -o noclobber; : > "$slot") 2>/dev/null; then
                echo "$slot"
                return 0
            fi
        fi
        sleep 0.5
    done
}

release_slot() { rm -f "$1"; }

download_file() {
    local raw_urls="$1"
    local output_path="$2"
    local min_size="${3:-10000000}"

    local slot
    slot=$(acquire_slot "$SEMAPHORE_DIR/dl" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    mkdir -p "$(dirname "$output_path")"

    IFS=' ' read -ra urls <<< "$raw_urls"

    for url in "${urls[@]}"; do
        local attempt=1
        while [ $attempt -le 5 ]; do
            log "Downloading (attempt $attempt/5): $(basename "$output_path")"

            rm -f "$output_path.tmp"

            local wget_args=(--progress=bar:force:noscroll --continue --tries=3 --timeout=180 --no-check-certificate)

            if [[ "$url" == *huggingface.co* && -n "${HF_TOKEN:-}" ]]; then
                wget_args+=(--header="Authorization: Bearer $HF_TOKEN")
            fi

            if wget "${wget_args[@]}" "$url" -O "$output_path.tmp"; then
                local actual_size=$(stat -c %s "$output_path.tmp" 2>/dev/null || echo 0)
                log "Downloaded temp file size: $(numfmt --to=iec $actual_size)"

                if [ "$actual_size" -gt 0 ] && [ "$actual_size" -ge "$min_size" ]; then
                    mv "$output_path.tmp" "$output_path"
                    log "✓ SUCCESS: $(basename "$output_path") ($(numfmt --to=iec $actual_size))"
                    return 0
                fi
            fi

            rm -f "$output_path.tmp"
            sleep 10
            attempt=$((attempt + 1))
        done
    done

    log "✗ FAILED after retries: $(basename "$output_path")"
    return 1
}

install_extensions() {
    local -a exts=()
    while IFS= read -r -d '' e; do [[ -n "$e" ]] && exts+=("$e"); done < <(merge_with_env "EXTENSIONS" "${EXTENSIONS[@]}")
    [[ ${#exts[@]} -eq 0 ]] && return

    log "Installing ${#exts[@]} extensions..."
    local ext_dir="${FORGE_DIR}/extensions"
    mkdir -p "$ext_dir"
    for url in "${exts[@]}"; do
        (
            local name=$(basename "$url" .git)
            local target="$ext_dir/$name"
            if [[ -d "$target/.git" ]]; then
                (cd "$target" && git pull --quiet) || log "[WARN] Update failed: $name"
            else
                git clone --quiet --depth 1 "$url" "$target" || log "[WARN] Clone failed: $name"
            fi
        ) &
    done
    wait
}

install_civitai_models() {
    local -a models=()
    while IFS= read -r -d '' m; do [[ -n "$m" ]] && models+=("$m"); done < <(merge_with_env "CIVITAI_MODELS" "${CIVITAI_MODELS_DEFAULT[@]}")
    [[ ${#models[@]} -eq 0 ]] && { log "No models configured"; return 0; }

    log "Downloading ${#models[@]} Flux model(s)/encoder(s)/LoRA(s)..."
    for entry in "${models[@]}"; do
        (
            IFS='|' read -r urls path <<< "$entry"
            urls=$(normalize_entry "$urls")
            path=$(normalize_entry "$path")
            [[ -z "$urls" || -z "$path" ]] && return

            local min_size=10000000
            if [[ "$path" == *flux1-dev-bnb-nf4* ]]; then min_size=11000000000; fi
            if [[ "$path" == *t5xxl_fp16* ]]; then min_size=9000000000; fi

            download_file "$urls" "$path" "$min_size"
        ) &
    done
    wait
}

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_extensions
    install_civitai_models

    log "✅ Provisioning finished successfully! (Flux + bitsandbytes ready)"
}

main
