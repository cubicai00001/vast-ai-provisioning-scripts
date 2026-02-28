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
    # Pony Diffusion V6 XL - HF mirror FIRST (reliable), Civitai as fallback
    "https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy (Otoko No Ko) v1.0
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"

    # Femboy v1.0
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"

    # Femboi Full v1.0
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"

    # femboysXL v1.0
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"
)

WGET_DOWNLOADS_DEFAULT=()

### End Configuration ###

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message"
}

script_cleanup() {
    log "Cleaning up semaphore directory..."
    rm -rf "$SEMAPHORE_DIR"
    find "$MODELS_DIR" -name "*.lock" -type f -mmin +60 -delete 2>/dev/null || true
    rm -f /.provisioning  # Force complete provisioning
}

script_error() {
    local exit_code=$?
    local line_number=$1
    log "[ERROR] Provisioning script failed at line $line_number with exit code $exit_code"
    exit "$exit_code"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

normalize_entry() {
    local entry="$1"
    entry=$(echo "$entry" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
    echo "$entry"
}

parse_env_array() {
    local env_var_name="$1"
    local env_value="${!env_var_name:-}"

    if [[ -n "$env_value" ]]; then
        local -a result=()
        IFS=';' read -ra entries <<< "$env_value"
        for entry in "${entries[@]}"; do
            entry=$(normalize_entry "$entry")
            [[ -z "$entry" || "$entry" == \#* ]] && continue
            result+=("$entry")
        done
        if [[ ${#result[@]} -gt 0 ]]; then
            printf '%s\0' "${result[@]}"
        fi
    fi
}

merge_with_env() {
    local env_var_name="$1"
    shift
    local -a default_array=("$@")
    local env_value="${!env_var_name:-}"

    if [[ ${#default_array[@]} -gt 0 ]]; then
        for entry in "${default_array[@]}"; do
            entry=$(normalize_entry "$entry")
            [[ -z "$entry" || "$entry" == \#* ]] && continue
            printf '%s\0' "$entry"
        done
    fi

    if [[ -n "$env_value" ]]; then
        echo "[merge_with_env] Adding entries from $env_var_name environment variable" >&2
        parse_env_array "$env_var_name"
    fi
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
    local auth_type="${3:-}"
    local max_retries=15
    local retry_delay=10

    IFS=' ' read -ra urls <<< "$raw_urls"

    local slot
    slot=$(acquire_slot "$SEMAPHORE_DIR/dl" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    local output_dir output_file use_content_disposition=false
    if [[ "$output_path" == */ ]]; then
        output_dir="${output_path%/}"
        use_content_disposition=true
    else
        output_dir="$(dirname "$output_path")"
        output_file="$(basename "$output_path")"
    fi

    mkdir -p "$output_dir"

    local auth_header=""
    local token_param=""
    if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        log "Using CIVITAI_TOKEN for authenticated download (masked: ${CIVITAI_TOKEN:0:4}...)"
        auth_header="Authorization: Bearer $CIVITAI_TOKEN"
        token_param="?token=$CIVITAI_TOKEN"
    fi

    local url_hash
    url_hash=$(printf '%s' "${urls[*]}" | md5sum | cut -d' ' -f1)
    local lockfile="${output_dir}/.download_${url_hash}.lock"

    (
        if ! flock -x -w 600 200; then
            log "[ERROR] Lock timeout for $output_path after 600s"
            exit 1
        fi

        if [[ -f "$output_dir/$output_file" && -s "$output_dir/$output_file" ]]; then
            log "File exists and non-zero size: $output_dir/$output_file (skipping)"
            exit 0
        fi

        for base_url in "${urls[@]}"; do
            local url="${base_url}${token_param}"  # Append token as query param (fixes many 400s)

            local attempt=1
            local current_delay=$retry_delay

            while [ $attempt -le $max_retries ]; do
                log "Downloading from $url (attempt $attempt/$max_retries)..."

                local wget_args=(
                    --timeout=120
                    --tries=1
                    --continue
                    --progress=dot:giga
                    --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                    --no-check-certificate
                )

                if [[ -n "$auth_header" ]]; then
                    wget_args+=(--header="$auth_header")
                fi

                if [[ "$use_content_disposition" == true ]]; then
                    wget_args+=(--content-disposition -P "$output_dir")
                else
                    wget_args+=(-O "$output_dir/$output_file.tmp")
                fi

                if wget "${wget_args[@]}" "$url" 2>&1; then
                    if [[ "$use_content_disposition" == false ]]; then
                        mv "$output_dir/$output_file.tmp" "$output_dir/$output_file"
                    fi
                    log "Successfully downloaded to: $output_dir"
                    exit 0
                fi

                log "Failed from $url (attempt $attempt), retrying in ${current_delay}s..."
                sleep $current_delay
                current_delay=$((current_delay * 2))
                attempt=$((attempt + 1))
            done

            log "All retries failed for $url, trying next source."
        done

        log "[ERROR] All sources failed for $output_path after max retries"
        exit 1
    ) 200>"$lockfile"

    local result=$?
    rm -f "$lockfile" "$output_dir/$output_file.tmp"
    return $result
}

# ... (rest of the script remains the same: log, cleanup, error trap, normalize, parse/merge, acquire/release, has_valid_* funcs, download_hf_file unchanged, install_* funcs, main)

main() {
    mkdir -p "$SEMAPHORE_DIR"

    install_apt_packages
    install_pip_packages
    install_extensions
    install_hf_models
    install_civitai_models
    install_wget_downloads

    log "Provisioning complete! Check models in /workspace/stable-diffusion-webui-forge/models"
}

main
