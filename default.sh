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
    # Pony Diffusion V6 XL (primary with mirrors)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors https://tensor.art/models/717274695390638697 | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy (Otoko No Ko) v1.0 (primary; no mirror, abandon on fail)
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"

    # Femboy v1.0 (primary)
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"

    # Femboi Full v1.0 (primary)
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"

    # femboysXL v1.0 (primary; no mirror)
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Alternatives (similar job: femboy/male for Pony base)
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor | $MODELS_DIR/Lora/male_mix_pony.safetensors"  # Male Mix Pony v5.0
    "https://civitai.com/api/download/models/1861600?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_pony.safetensors"  # Femboy pony v1.1
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | $MODELS_DIR/Lora/curvy_femboy_xl.safetensors"  # CurvyFemboyXL (HF)
)

### End Configuration ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

script_cleanup() {
    log "Cleaning up semaphore directory..."
    rm -rf "$SEMAPHORE_DIR"
    find "$MODELS_DIR" -name "*.lock" -type f -mmin +60 -delete 2>/dev/null || true
    rm -f /.provisioning
}

script_error() {
    local exit_code=$?
    local line=$1
    log "[ERROR] Script failed at line $line (exit code $exit_code)"
    exit $exit_code
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

normalize_entry() {
    echo "$1" | tr -d '\n\r' | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

parse_env_array() {
    local var="$1"
    local value="${!var:-}"
    if [[ -z "$value" ]]; then return; fi
    local -a arr=()
    IFS=';' read -ra parts <<< "$value"
    for p in "${parts[@]}"; do
        p=$(normalize_entry "$p")
        [[ -z "$p" || "$p" == \#* ]] && continue
        arr+=("$p")
    done
    if [[ ${#arr[@]} -gt 0 ]]; then
        printf '%s\0' "${arr[@]}"
    fi
}

merge_with_env() {
    local var="$1"
    shift
    local -a defaults=("$@")
    local -a result=()

    for d in "${defaults[@]}"; do
        d=$(normalize_entry "$d")
        [[ -z "$d" || "$d" == \#* ]] && continue
        result+=("$d")
    done

    while IFS= read -r -d '' e; do
        result+=("$e")
    done < <(parse_env_array "$var")

    printf '%s\0' "${result[@]}"
}

acquire_slot() {
    local prefix="$1" max="$2"
    local dir="$(dirname "$prefix")" base="$(basename "$prefix")"
    while true; do
        local cnt=$(find "$dir" -maxdepth 1 -name "${base}_*" 2>/dev/null | wc -l)
        if (( cnt < max )); then
            local slot="${prefix}_$$_${RANDOM}_${RANDOM}"
            if (set -o noclobber; : > "$slot") 2>/dev/null; then
                echo "$slot"
                return 0
            fi
        fi
        sleep 0.4
    done
}

release_slot() { rm -f "$1"; }

download_file() {
    local raw_urls="$1" dest="$2" auth_type="${3:-}"
    local max_retries=15 base_delay=10

    IFS=' ' read -ra sources <<< "$raw_urls"

    local slot=$(acquire_slot "$SEMAPHORE_DIR/dl" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    local out_dir="$(dirname "$dest")" out_file="$(basename "$dest")"
    mkdir -p "$out_dir"

    if [[ -f "$dest" && -s "$dest" ]]; then
        log "Already exists and non-empty: $dest → skipping"
        return 0
    fi

    log "Starting download for $dest"
    log "  Sources (${#sources[@]}): ${sources[*]}"
    if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        log "  CIVITAI_TOKEN is set (length ${#CIVITAI_TOKEN})"
    else
        log "  No CIVITAI_TOKEN detected"
    fi

    local auth_header=""
    local token_query=""
    if [[ -n "${CIVITAI_TOKEN:-}" ]]; then
        auth_header="Authorization: Bearer $CIVITAI_TOKEN"
        token_query="?token=$CIVITAI_TOKEN"
    fi

    local hash=$(printf '%s' "${sources[*]}" | md5sum | cut -d' ' -f1)
    local lock="${out_dir}/.dl_${hash}.lock"

    (
        if ! flock -x -w 600 200; then
            log "[ERROR] Lock timeout for $dest"
            exit 1
        fi

        local attempt_count=0
        local source_idx=0
        while (( attempt_count < max_retries * ${#sources[@]} )); do
            local url_base="${sources[source_idx]}"
            local url="$url_base"
            if [[ $url_base == *civitai* ]]; then
                url="${url_base}${token_query}"
            fi

            log "Trying source $((source_idx + 1))/${#sources[@] } : $url"

            if curl -L --fail --retry 1 --retry-delay 2 \
                --connect-timeout 60 --max-time 600 \
                ${auth_header:+-H "$auth_header"} \
                -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --no-progress-meter \
                -o "$dest.tmp" "$url"; then

                mv "$dest.tmp" "$dest"
                log "SUCCESS → $dest from $url"
                exit 0
            fi

            log "  Failed → cycling to next source after ${base_delay}s..."
            sleep $base_delay
            ((attempt_count++))
            ((source_idx = (source_idx + 1) % ${#sources[@]} ))
        done

        log "[FAIL] All sources cycled and failed for $dest after $attempt_count attempts"
        exit 1
    ) 200>"$lock"

    local rc=$?
    rm -f "$lock" "$dest.tmp"
    return $rc
}

install_apt_packages() {
    (( ${#APT_PACKAGES[@]} == 0 )) && return
    log "Installing APT packages..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
}

install_pip_packages() {
    (( ${#PIP_PACKAGES[@]} == 0 )) && return
    log "Installing pip packages..."
    uv pip install --no-cache-dir "${PIP_PACKAGES[@]}"
}

install_extensions() {
    local -a exts=()
    while IFS= read -r -d '' e; do [[ -n "$e" ]] && exts+=("$e"); done < <(merge_with_env "EXTENSIONS" "${EXTENSIONS[@]}")
    (( ${#exts[@]} == 0 )) && return

    log "Installing/updating ${#exts[@]} extension(s)..."

    export GIT_CONFIG_GLOBAL=/tmp/git-safe
    echo "[safe]" > "$GIT_CONFIG_GLOBAL"
    echo "    directory = *" >> "$GIT_CONFIG_GLOBAL"

    local d="${FORGE_DIR}/extensions"
    mkdir -p "$d"

    for url in "${exts[@]}"; do
        (
            local name=$(basename "${url%.git}")
            local tgt="$d/$name"
            if [[ -d "$tgt/.git" ]]; then
                log "  Updating $name"
                (cd "$tgt" && git pull --quiet) || log "  [WARN] pull failed: $name"
            else
                log "  Cloning $name"
                git clone --quiet --depth 1 "$url" "$tgt" || log "  [WARN] clone failed: $name"
            fi
        ) &
    done
    wait
}

install_civitai_models() {
    local -a models=()
    while IFS= read -r -d '' m; do [[ -n "$m" ]] && models+=("$m"); done < <(merge_with_env "CIVITAI_MODELS" "${CIVITAI_MODELS_DEFAULT[@]}")
    (( ${#models[@]} == 0 )) && { log "No models configured"; return; }

    log "Downloading ${#models[@]} model file(s) with source cycling..."

    for entry in "${models[@]}"; do
        IFS='|' read -r urls dest <<< "$entry"
        urls=$(normalize_entry "$urls")
        dest=$(normalize_entry "$dest")
        [[ -z "$urls" || -z "$dest" ]] && continue

        if download_file "$urls" "$dest" "civitai" == 0; then
            log "Model $dest downloaded successfully"
        else
            log "Failed all sources for $dest — abandoning and continuing to next alternative"
        fi
    done
}

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_apt_packages
    install_pip_packages
    install_extensions
    install_civitai_models

    log "Provisioning finished."
}

main
