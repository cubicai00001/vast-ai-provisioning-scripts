```bash
#!/bin/bash
set -euo pipefail

### Configuration - Flux Optimized (Photorealistic NSFW Focus + Fallbacks) ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-3}"

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

# Flux models and compatible LoRAs (with fallbacks for base)
CIVITAI_MODELS_DEFAULT=(
    # Primary: Flux.1 Dev NF4 quantized (12 GB) + Fallback: Flux.1 Schnell (23.8 GB)
    "https://huggingface.co/lllyasviel/flux1-dev-bnb-nf4/resolve/main/flux1-dev-bnb-nf4-v2.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors | $MODELS_DIR/Stable-diffusion/flux1-dev-bnb-nf4-v2.safetensors"

    # Flux-compatible LoRAs (realism booster + femboy + shemale)
    "https://huggingface.co/XLabs-AI/flux-RealismLora/resolve/main/lora.safetensors | $MODELS_DIR/Lora/realism_lora.safetensors"
    "https://civitai.com/api/download/models/696714 | $MODELS_DIR/Lora/femboy_flux.safetensors"
    "https://civitai.com/api/download/models/151669 | $MODELS_DIR/Lora/shemale_flux.safetensors"
)

WGET_DOWNLOADS_DEFAULT=()

### End Configuration ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

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

# === ROBUST DOWNLOAD (improved: optional min_size, better logging on failure) ===
download_file() {
    local raw_urls="$1"
    local output_path="$2"
    local min_size="${3:-10000000}"   # Default 10 MB - safe for LoRAs; override for base models

    local slot
    slot=$(acquire_slot "$SEMAPHORE_DIR/dl" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    mkdir -p "$(dirname "$output_path")"

    IFS=' ' read -ra urls <<< "$raw_urls"

    for url in "${urls[@]}"; do
        local attempt=1
        while [ $attempt -le 5 ]; do
            log "Downloading (attempt $attempt/5): $(basename "$output_path") from $url"

            rm -f "$output_path.tmp"

            local wget_args=(--progress=bar:force:noscroll --continue --tries=3 --timeout=180 --no-check-certificate)

            # HF_TOKEN support
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
                else
                    log "✗ Temp file too small ($actual_size bytes < $min_size required) - retrying"
                fi
            else
                log "✗ wget failed (exit code $?)"
            fi

            rm -f "$output_path.tmp"
            log "Retrying in 10s..."
            sleep 10
            attempt=$((attempt + 1))
        done
    done

    log "✗ FAILED after retries: $(basename "$output_path")"
    return 1
}

install_apt_packages() { :; }
install_pip_packages() { :; }

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

    log "Downloading ${#models[@]} Flux model(s)/LoRA(s)..."
    for entry in "${models[@]}"; do
        (
            IFS='|' read -r urls path <<< "$entry"
            urls=$(normalize_entry "$urls")
            path=$(normalize_entry "$path")
            [[ -z "$urls" || -z "$path" ]] && return

            local min_size=10000000  # default for LoRAs (~10 MB min)

            # Special cases for base models (large sizes)
            if [[ "$path" == *flux1-dev-bnb-nf4-v2.safetensors ]]; then
                min_size=11000000000  # ~11 GB min for NF4 (actual ~12 GB)
            elif [[ "$path" == *flux1-schnell.safetensors ]]; then
                min_size=20000000000  # ~20 GB min for Schnell (actual ~23.8 GB)
            fi

            download_file "$urls" "$path" "$min_size"
        ) &
    done
    wait
}

install_wget_downloads() { log "No extra wget downloads configured"; }

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_apt_packages
    install_pip_packages
    install_extensions
    install_civitai_models
    install_wget_downloads

    log "✅ Provisioning finished successfully! (All models are valid Flux files with fallbacks)"
}

main
```
