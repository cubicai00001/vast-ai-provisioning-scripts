#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
FORGE_DIR="${WORKSPACE_DIR}/stable-diffusion-webui-forge"
MODELS_DIR="${FORGE_DIR}/models"
SEMAPHORE_DIR="${WORKSPACE_DIR}/download_sem_$$"
MAX_PARALLEL="${MAX_PARALLEL:-1}"

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

CIVITAI_MODELS_DEFAULT=(
    # Pony Diffusion V6 XL - multiple sources (Civitai → HF → Tensor.art mirror)
    "https://civitai.com/api/download/models/290640?type=Model&format=SafeTensor&size=pruned&fp=fp16 https://huggingface.co/LyliaEngine/Pony_Diffusion_V6_XL/resolve/main/ponyDiffusionV6XL.safetensors https://tensor.art/models/717274695390638697 | $MODELS_DIR/Stable-diffusion/ponyDiffusionV6XL.safetensors"

    # Femboy (Otoko No Ko) v1.0
    "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_otoko_no_ko.safetensors"

    # Femboy v1.0
    "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16 | $MODELS_DIR/Lora/femboy.safetensors"

    # Femboi Full v1.0
    "https://civitai.com/api/download/models/20797 | $MODELS_DIR/Lora/femboi_full_v1.safetensors"

    # femboysXL v1.0
    "https://civitai.com/api/download/models/324974 | $MODELS_DIR/Lora/femboysxl_v1.safetensors"

    # Fallback alternatives (same job if primaries fail)
    "https://civitai.com/api/download/models/2625213?type=Model&format=SafeTensor | $MODELS_DIR/Lora/male_mix_pony.safetensors"
    "https://civitai.com/api/download/models/1861600?type=Model&format=SafeTensor | $MODELS_DIR/Lora/femboy_pony.safetensors"
    "https://huggingface.co/datasets/CollectorN01/PonyXL-Lora-MyAhhArchiveCN01/resolve/main/concept/CurvyFemboyXL.safetensors | $MODELS_DIR/Lora/curvy_femboy_xl.safetensors"
)

### End Configuration ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

script_cleanup() {
    log "Cleaning up semaphore directory..."
    rm -rf "$SEMAPHORE_DIR" 2>/dev/null || true
    find "$MODELS_DIR" -name "*.lock" -type f -mmin +60 -delete 2>/dev/null || true
    rm -f /.provisioning
}

script_error() {
    local exit_code=$?
    local line=$1
    log "[ERROR] Script failed at line $line (exit code $exit_code)"
    exit "$exit_code"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

normalize_entry() {
    echo "$1" | tr -d '\n\r' | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

parse_env_array() {
    local var="$1"
    local value="${!var:-}"
    [[ -z "$value" ]] && return
    local -a arr=()
    IFS=';' read -ra parts <<< "$value"
    for p in "${parts[@]}"; do
        p=$(normalize_entry "$p")
        [[ -z "$p" || "$p" == \#* ]] && continue
        arr+=("$p")
    done
    [[ ${#arr[@]} -gt 0 ]] && printf '%s\0' "${arr[@]}"
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
    local raw_urls="$1" dest="$2"
    local max_retries=12 base_delay=8

    IFS=' ' read -ra sources <<< "$raw_urls"

    local slot=$(acquire_slot "$SEMAPHORE_DIR/dl" "$MAX_PARALLEL")
    trap 'release_slot "$slot"' RETURN

    local out_dir="$(dirname "$dest")" out_file="$(basename "$dest")"
    mkdir -p "$out_dir"

    if [[ -f "$dest" && -s "$dest" ]]; then
        log "Already exists: $dest (skipping)"
        return 0
    fi

    log "Starting download: $dest"
    log "  Sources: ${sources[*]}"
    [[ -n "${CIVITAI_TOKEN:-}" ]] && log "  CIVITAI_TOKEN detected (length ${#CIVITAI_TOKEN})"

    local auth_header="" token_query=""
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

        local src_idx=0 attempt_total=0
        while (( attempt_total < max_retries * ${#sources[@]} )); do
            local url_base="${sources[src_idx]}"
            local url="$url_base"
            [[ $url_base == *civitai* ]] && url="${url_base}${token_query}"

            log "Trying source: $url"

            if curl -L --fail --retry 1 --retry-delay 2 \
                --connect-timeout 60 --max-time 600 \
                ${auth_header:+-H "$auth_header"} \
                -A "Mozilla/5.0" --no-progress-meter \
                -o "$dest.tmp" "$url"; then

                mv "$dest.tmp" "$dest"
                log "SUCCESS → $dest"
                exit 0
            fi

            log "  Failed — waiting ${base_delay}s then cycling source..."
            sleep $base_delay
            ((attempt_total++))
            ((src_idx = (src_idx + 1) % ${#sources[@]} ))
        done

        log "[FAIL] All sources exhausted for $dest"
        exit 1
    ) 200>"$lock"

    local rc=$?
    rm -f "$lock" "$dest.tmp"
    return $rc
}

install_extensions() {
    local -a exts=()
    while IFS= read -r -d '' e; do [[ -n "$e" ]] && exts+=("$e"); done < <(merge_with_env "EXTENSIONS" "${EXTENSIONS[@]}")
    (( ${#exts[@]} == 0 )) && return

    log "Installing ${#exts[@]} extension(s)..."
    local d="${FORGE_DIR}/extensions"
    mkdir -p "$d"

    for url in "${exts[@]}"; do
        (
            local name=$(basename "${url%.git}")
            local tgt="$d/$name"
            if [[ -d "$tgt/.git" ]]; then
                (cd "$tgt" && git pull --quiet) || log "  [WARN] Update failed: $name"
            else
                git clone --quiet --depth 1 "$url" "$tgt" || log "  [WARN] Clone failed: $name"
            fi
        ) &
    done
    wait
}

install_models() {
    local -a models=()
    while IFS= read -r -d '' m; do [[ -n "$m" ]] && models+=("$m"); done < <(merge_with_env "CIVITAI_MODELS" "${CIVITAI_MODELS_DEFAULT[@]}")
    (( ${#models[@]} == 0 )) && { log "No models configured"; return; }

    log "Downloading ${#models[@]} model(s) with source cycling..."

    for entry in "${models[@]}"; do
        IFS='|' read -r urls dest <<< "$entry"
        urls=$(normalize_entry "$urls")
        dest=$(normalize_entry "$dest")
        [[ -z "$urls" || -z "$dest" ]] && continue

        if download_file "$urls" "$dest"; then
            log "✓ $dest downloaded"
        else
            log "✗ Failed all sources for $dest — continuing to next model"
        fi
    done
}

main() {
    mkdir -p "$SEMAPHORE_DIR"
    touch /.provisioning

    install_extensions
    install_models

    log "Provisioning finished."
}

main
