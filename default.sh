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
    "https://github.com/Bing-su/adetailer"
)

HF_MODELS_DEFAULT=(
    "https://huggingface.co/cyberdelia/CyberRealisticPony/resolve/main/CyberRealistic_Pony_v16_Prune_fp16.safetensors | $MODELS_DIR/Stable-diffusion/cyberrealistic_pony_v16_pruned_fp16.safetensors"
)

CIVITAI_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL - BEST BASE (King for femboy/shemale/crossdresser)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy (Otoko No Ko) - v1.0 → trigger: otoko no ko, femboy (weight 0.6-0.9)
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"

    # Femboy v1.0 → trigger: femboy, feminine, flat chest, cute
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"

    # Femboi Full (Femboy/Trap Concept LORA) v1.0
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"

    # femboysXL (92 dim) v1.0
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Pony Realism Enhancer ✨ - v2.0 (adds photoreal skin/detail boost; weight 0.5-0.9)
    "https://civitai.com/api/download/models/927305 | $MODELS_DIR/Lora/pony_realism_enhancer.safetensors"
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
    local raw_urls="$1"
    local output_path="$2"
    local auth_type="${3:-}"
    local max_retries=5
    local retry_delay=2

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
    if [[ "$auth_type" == "hf" ]] && [[ -n "${HF_TOKEN:-}" ]]; then
        auth_header="Authorization: Bearer $HF_TOKEN"
    elif [[ "$auth_type" == "civitai" ]] && [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        auth_header="Authorization: Bearer $CIVITAI_TOKEN"
    fi

    local url_hash
    url_hash=$(printf '%s' "${urls[*]}" | md5sum | cut -d' ' -f1)
    local lockfile="${output_dir}/.download_${url_hash}.lock"

    (
        if ! flock -x -w 300 200; then
            log "[ERROR] Could not acquire lock for download after 300s: ${urls[*]}"
            exit 1
        fi

        if [[ "$use_content_disposition" == false && -f "$output_dir/$output_file" ]] || [[ "$use_content_disposition" == true ]]; then
            # For content disposition, we'll check after getting filename
            :
        else
            if [[ -f "$output_dir/$output_file" ]]; then
                log "File already exists: $output_dir/$output_file (skipping)"
                exit 0
            fi
        fi

        for url in "${urls[@]}"; do
            local attempt=1
            local current_delay=$retry_delay

            while [ $attempt -le $max_retries ]; do
                log "Downloading from $url (attempt $attempt/$max_retries)..."

                local wget_args=(
                    --timeout=60
                    --tries=1
                    --continue
                    --progress=dot:giga
                )

                if [[ -n "$auth_header" ]]; then
                    wget_args+=(--header="$auth_header")
                fi

                if [[ "$use_content_disposition" == true ]]; then
                    local remote_filename
                    remote_filename=$(get_content_disposition_filename "$url" "$auth_header")
                    if [[ -n "$remote_filename" && -f "$output_dir/$remote_filename" ]]; then
                        log "File already exists: $output_dir/$remote_filename (skipping)"
                        exit 0
                    fi
                    wget_args+=(--content-disposition -P "$output_dir")
                else
                    wget_args+=(-O "$output_dir/$output_file")
                fi

                if wget "${wget_args[@]}" "$url" 2>&1; then
                    log "Successfully downloaded to: $output_dir"
                    exit 0
                fi

                log "Download failed from $url (attempt $attempt/$max_retries), retrying in ${current_delay}s..."
                sleep $current_delay
                current_delay=$((current_delay * 2))
                attempt=$((attempt + 1))
            done

            log "All retries failed for $url, trying next source if available."
        done

        log "[ERROR] Failed to download $output_path from all sources after $max_retries attempts each"
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
    : > "$GIT_CONFIG_GLOBAL"
    echo "[safe]" >> "$GIT_CONFIG_GLOBAL"
    echo "    directory = *" >> "$GIT_CONFIG_GLOBAL"

    local ext_dir="${FORGE_DIR}/extensions"
    mkdir -p "$ext_dir"

    for repo_url in "${extensions[@]}"; do
        (
            local repo_name
            repo_name=$(basename "$repo_url" .git)

            local target_dir="${ext_dir}/${repo_name}"

            if [[ -d "$target_dir/.git" ]]; then
                log "Extension already installed: $repo_name (updating)"
                cd "$target_dir" || exit 1
                git pull --quiet || log "[WARNING] Failed to update $repo_name"
            else
                log "Installing extension: $repo_name"
                git clone --quiet --depth 1 "$repo_url" "$target_dir" || exit 1
            fi
        ) &
    done

    wait
}

install_hf_models() {
    local -a hf_models=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && hf_models+=("$entry")
    done < <(merge_with_env "HF_MODELS" "${HF_MODELS_DEFAULT[@]}")

    if [[ ${#hf_models[@]} -eq 0 ]]; then
        log "No HuggingFace models to download"
        return 0
    fi

    if has_valid_hf_token; then
        log "Downloading ${#hf_models[@]} HuggingFace model(s)..."
        for entry in "${hf_models[@]}"; do
            IFS='|' read -r url output_path <<< "$entry"
            url=$(echo "$url" | sed 's/[[:space:]]*$//')
            output_path=$(echo "$output_path" | sed 's/^[[:space:]]*//')
            if [[ -n "$url" && -n "$output_path" ]]; then
                download_hf_file "$url" "$output_path" &
            fi
        done
        wait
    else
        log "Skipping HuggingFace models (no valid HF_TOKEN)"
    fi
}

install_civitai_models() {
    local -a civitai_models=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && civitai_models+=("$entry")
    done < <(merge_with_env "CIVITAI_MODELS" "${CIVITAI_MODELS_DEFAULT[@]}")

    if [[ ${#civitai_models[@]} -eq 0 ]]; then
        log "No Civitai models to download"
        return 0
    fi

    log "Downloading ${#civitai_models[@]} Civitai model(s)..."

    for entry in "${civitai_models[@]}"; do
        (
            IFS='|' read -r raw_urls output_path <<< "$entry"
            raw_urls=$(echo "$raw_urls" | sed 's/[[:space:]]*$//')
            output_path=$(echo "$output_path" | sed 's/^[[:space:]]*//')
            if [[ -n "$raw_urls" && -n "$output_path" ]]; then
                download_file "$raw_urls" "$output_path" "civitai"
            fi
        ) &
    done

    wait
}

install_wget_downloads() {
    local -a wget_downloads=()
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && wget_downloads+=("$entry")
    done < <(merge_with_env "WGET_DOWNLOADS" "${WGET_DOWNLOADS_DEFAULT[@]}")

    if [[ ${#wget_downloads[@]} -eq 0 ]]; then
        log "No additional wget downloads"
        return 0
    fi

    log "Downloading ${#wget_downloads[@]} additional file(s) via wget..."

    for entry in "${wget_downloads[@]}"; do
        (
            IFS='|' read -r url output_path <<< "$entry"
            url=$(echo "$url" | sed 's/[[:space:]]*$//')
            output_path=$(echo "$output_path" | sed 's/^[[:space:]]*//')
            if [[ -n "$url" && -n "$output_path" ]]; then
                download_file "$url" "$output_path"
            fi
        ) &
    done

    wait
}

main() {
    mkdir -p "$SEMAPHORE_DIR"

    install_apt_packages
    install_pip_packages
    install_extensions
    install_hf_models
    install_civitai_models
    install_wget_downloads

    log "Provisioning complete!"
}

main
