#!/bin/bash
set -euo pipefail

### Pony Diffusion XL Optimized - v2.1 (Full script + HF_TOKEN support) ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-3}"

# ONLY Pony/SDXL compatible models (no SD 1.5 LoRAs)
CIVITAI_MODELS_DEFAULT=(
    "https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor | $MODELS_DIR/Lora/male_mix_pony.safetensors"
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | $MODELS_DIR/Lora/curvy_femboy_xl.safetensors"
)

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

### End Configuration ###

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

script_cleanup() {
    log "Cleaning up..."
    rm -rf "$SEMAPHORE_DIR"
    rm -f /.provisioning
}

script_error() {
    local exit_code=$?
    log "[ERROR] Provisioning failed at line $1 with code $exit_code"
    exit "$exit_code"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

normalize_entry() {
    local entry="$1"
    echo "$entry" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//'
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

release_slot() {
    rm -f "$1"
}

download_file() {
    local raw_urls="$1"
    local output_path="$2"
    local slot
    slot=$(acquire_slot "$SEMAPHORE_DIR/dl" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    mkdir -p "$(dirname "$output_path")"

    IFS=' ' read -ra urls <<< "$raw_urls"

    for base_url in "${urls[@]}"; do
        local url="$base_url"
        local args=(--timeout=120 --tries=3 --continue --progress=dot:giga --no-check-certificate)

        # Add HF_TOKEN for Hugging Face URLs
        if [[ "$url" == *huggingface.co* && -n "${HF_TOKEN:-}" ]]; then
            args+=(--header="Authorization: Bearer $HF_TOKEN")
            log "Downloading (HF_TOKEN used): $output_path"
        fi

        if wget "${args[@]}" -O "$output_path.tmp" "$url" && mv "$output_path.tmp" "$output_path"; then
            log "SUCCESS: $output_path"
            return 0
        fi
    done
    log "[ERROR] Failed to download $output_path"
    return 1
}

install_apt_packages() { :; }   # none needed
install_pip_packages() { :; }   # none needed

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

    log "Downloading ${#models[@]} PonyXL model(s)/LoRA(s)..."
    for entry in "${models[@]}"; do
        (
            IFS='|' read -r urls path <<< "$entry"
            urls=$(normalize_entry "$urls")
            path=$(normalize_entry "$path")
            [[ -n "$urls" && -n "$path" ]] && download_file "$urls" "$path"
        ) &
    done
    wait
}

install_wget_downloads() { log "No extra wget downloads"; }

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_apt_packages
    install_pip_packages
    install_extensions
    install_civitai_models
    install_wget_downloads

    log "✅ Provisioning finished successfully! (HF_TOKEN supported)"
    log "Base model + 3 XL LoRAs should now be in place."
}

main
