#!/bin/bash
set -euo pipefail

### Configuration ###
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
)

HF_MODELS_DEFAULT=()

CIVITAI_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL - BEST BASE (King for femboy/shemale/crossdresser)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16
    |$MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors
    |civitai"

    # Femboy (Otoko No Ko) - v1.0 → trigger: otoko no ko, femboy (weight 0.6-0.9)
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor
    |$MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors
    |civitai"

    # Femboy v1.0 → trigger: femboy, feminine, flat chest, cute
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16
    |$MODELS_DIR/Lora/femboy.safetensors
    |civitai"
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
    local slot_dir
    slot_dir="$(dirname "$prefix")"
    local slot_prefix
    slot_prefix="$(basename "$prefix")"

    while true; do
        local count
        count=$(find "$slot_dir" -maxdepth 1 -name "${slot_prefix}_*" 2>/dev/null | wc -l)
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

has_valid_hf_token() {
    [[ -n "${HF_TOKEN:-}" ]] || return 1
    local response
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET \
        "https://huggingface.co/api/whoami-v2" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

has_valid_civitai_token() {
    [[ -n "${CIVITAI_TOKEN:-}" ]] || return 1
    local response
    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET \
        "https://civitai.com/api/v1/models?hidden=1&limit=1" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")
    [[ "$response" -eq 200 ]]
}

download_hf_file() {
    local url="$1"
    local output_path="$2"
    local max_retries=5
    local retry_delay=2

    local slot
    slot=$(acquire_slot "$SEMAPHORE_DIR/hf" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    mkdir -p "$(dirname "$output_path")"
    local lockfile="${output_path}.lock"

    (
        if ! flock -x -w 300 200; then
            log "[ERROR] Could not acquire lock for $output_path after 300s"
            exit 1
        fi

        if [[ -f "$output_path" ]]; then
            log "File already exists: $output_path (skipping)"
            exit 0
        fi

        local repo file_path
        repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
        file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')

        if [[ -z "$repo" ]] || [[ -z "$file_path" ]]; then
            log "[ERROR] Invalid HuggingFace URL: $url"
            exit 1
        fi

        local temp_dir
        temp_dir=$(mktemp -d)
        local attempt=1
        local current_delay=$retry_delay

        while [[ $attempt -le $max_retries ]]; do
            log "Downloading $repo/$file_path (attempt $attempt/$max_retries)..."
            hf_command=$(command -v hf || command -v huggingface-cli)
            if "$hf_command" download "$repo" \
                "$file_path" \
                --local-dir "$temp_dir" \
                --cache-dir "$temp_dir/.cache" 2>&1; then

                if [[ -f "$temp_dir/$file_path" ]]; then
                    mv "$temp_dir/$file_path" "$output_path"
                    rm -rf "$temp_dir"
                    log "Successfully downloaded: $output_path"
                    exit 0
                fi
            fi

            log "Download failed (attempt $attempt/$max_retries), retrying in ${current_delay}s..."
            sleep $current_delay
            current_delay=$((current_delay * 2))
            attempt=$((attempt + 1))
        done

        log "[ERROR] Failed to download $output_path after $max_retries attempts"
        rm -rf "$temp_dir"
        exit 1
    ) 200>"$lockfile"

    local result=$?
    rm -f "$lockfile"
    return $result
}

get_content_disposition_filename() {
    local url="$1"
    local auth_header="${2:-}"
    local curl_args=(-sI -L --max-time 30)

    if [[ -n "$auth_header" ]]; then
        curl_args+=(-H "$auth_header")
    fi

    local headers
    headers=$(curl "${curl_args[@]}" "$url" 2>/dev/null)

    local filename
    filename=$(echo "$headers" | grep -i 'content-disposition:' | \
        sed -n 's/.*filename="\?\([^"]*\)"\?.*/\1/p' | \
        tail -1 | tr -d '\r')

    filename="${filename##*/}"
    echo "$filename"
}

download_file() {
    local url="$1"
    local output_path="$2"
    local auth_type="${3:-}"
    local max_retries=8           # artırıldı: daha fazla şans
    local retry_delay=4           # ilk retry'den sonra biraz daha uzun bekle

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

    # ────────────────────────────────────────────────
    # ★★★ DEĞİŞİKLİK: Bearer yerine query string token ★★★
    # ────────────────────────────────────────────────
    local auth_param=""
    if [[ "$auth_type" == "civitai" ]] && [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        if [[ "$url" == *\?* ]]; then
            auth_param="&token=${CIVITAI_TOKEN}"
        else
            auth_param="?token=${CIVITAI_TOKEN}"
        fi
    elif [[ "$auth_type" == "hf" ]] && [[ -n "${HF_TOKEN:-}" ]]; then
        auth_param="?token=${HF_TOKEN}"
    fi

    local full_url="${url}${auth_param}"

    local url_hash
    url_hash=$(printf '%s' "$full_url" | md5sum | cut -d' ' -f1)
    local lockfile="${output_dir}/.download_${url_hash}.lock"

    (
        if ! flock -x -w 300 200; then
            log "[ERROR] Could not acquire lock for download after 300s: $full_url"
            exit 1
        fi

        local attempt=1
        local current_delay=$retry_delay

        while [ $attempt -le $max_retries ]; do
            log "Downloading (attempt $attempt/$max_retries): $full_url"

            local wget_args=(
                --timeout=90               # artırıldı
                --tries=1
                --continue
                --progress=dot:giga
            )

            if [[ "$use_content_disposition" == true ]]; then
                local remote_filename
                remote_filename=$(get_content_disposition_filename "$full_url")
                if [[ -n "$remote_filename" && -f "$output_dir/$remote_filename" ]]; then
                    log "File already exists (content-disposition): $output_dir/$remote_filename (skipping)"
                    exit 0
                fi
                wget_args+=(--content-disposition -P "$output_dir")
            else
                if [[ -f "$output_dir/$output_file" ]]; then
                    log "File already exists: $output_dir/$output_file (skipping)"
                    exit 0
                fi
                wget_args+=(-O "$output_dir/$output_file")
            fi

            if wget "${wget_args[@]}" "$full_url" 2>&1; then
                log "Successfully downloaded to: $output_dir"
                exit 0
            fi

            log "Download failed (attempt $attempt/$max_retries), retrying in ${current_delay}s..."
            sleep $current_delay
            current_delay=$((current_delay * 2))
            attempt=$((attempt + 1))
        done

        log "[ERROR] Failed to download $full_url after $max_retries attempts"
        exit 1
    ) 200>"$lockfile"

    local result=$?
    rm -f "$lockfile"
    return $result
}

install_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 && -n "${APT_PACKAGES[*]}" ]]; then
        log "Installing APT packages..."
        sudo apt-get update
        sudo apt-get install -y "${APT_PACKAGES[@]}"
    fi
}

install_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 && -n "${PIP_PACKAGES[*]}" ]]; then
        log "Installing Python packages..."
        uv pip install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

install_extensions() {
    local -a extensions=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && extensions+=("$entry")
    done < <(merge_with_env "EXTENSIONS" "${EXTENSIONS[@]}")

    if [[ ${#extensions[@]} -eq 0 ]]; then
        log "No extensions to install"
        return 0
    fi

    log "Installing ${#extensions[@]} extension(s)..."

    export GIT_CONFIG_GLOBAL=/tmp/temporary-git-config

    for ext in "${extensions[@]}"; do
        log "Installing extension: $ext"
        git clone "$ext" "${FORGE_DIR}/extensions/$(basename "$ext")" || log "Failed to clone $ext"
    done
}

download_models() {
    local -a civitai_models=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && civitai_models+=("$entry")
    done < <(merge_with_env "CIVITAI_MODELS" "${CIVITAI_MODELS_DEFAULT[@]}")

    if [[ ${#civitai_models[@]} -eq 0 ]]; then
        log "No CivitAI models to download"
    else
        log "Queueing ${#civitai_models[@]} CivitAI model download(s)..."
        for model_entry in "${civitai_models[@]}"; do
            IFS='|' read -r url dest auth_type <<< "$model_entry"
            url=$(echo "$url" | xargs)
            dest=$(echo "$dest" | xargs)
            auth_type=$(echo "$auth_type" | xargs)

            [[ -z "$url" || -z "$dest" ]] && continue

            log "Queueing download: $url → $dest (auth: ${auth_type:-none})"
            download_file "$url" "$dest" "$auth_type" &
        done
        wait
    fi

    # HF modelleri (eğer varsa)
    local -a hf_models=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && hf_models+=("$entry")
    done < <(merge_with_env "HF_MODELS" "${HF_MODELS_DEFAULT[@]}")

    if [[ ${#hf_models[@]} -gt 0 ]]; then
        log "Downloading ${#hf_models[@]} HuggingFace model(s)..."
        for hf_entry in "${hf_models[@]}"; do
            IFS='|' read -r url dest <<< "$hf_entry"
            url=$(echo "$url" | xargs)
            dest=$(echo "$dest" | xargs)
            [[ -z "$url" || -z "$dest" ]] && continue
            download_hf_file "$url" "$dest" &
        done
        wait
    fi
}

main() {
    log "Starting provisioning script..."

    if has_valid_civitai_token; then
        log "CIVITAI_TOKEN is valid"
    else
        log "Warning: CIVITAI_TOKEN is missing or invalid"
    fi

    if has_valid_hf_token; then
        log "HF_TOKEN is valid"
    else
        log "Warning: HF_TOKEN is missing or invalid"
    fi

    install_apt_packages
    install_pip_packages
    install_extensions
    download_models

    log "Provisioning completed successfully!"
}

main
