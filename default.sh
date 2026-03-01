#!/bin/bash
set -euo pipefail

echo "=== Femboy Domination FINAL Provisioning v3 ==="

# Activate venv (critical)
[[ -f /venv/main/bin/activate ]] && source /venv/main/bin/activate

uv pip install --upgrade setuptools wheel packaging

FORGE_DIR="/workspace/stable-diffusion-webui-forge"
MODELS="${FORGE_DIR}/models"

mkdir -p "${MODELS}/Stable-diffusion" "${MODELS}/Lora" "${MODELS}/iclight"

# Extensions (stable only)
EXTS=(
  "https://github.com/Bing-su/adetailer"
  "https://github.com/Mikubill/sd-webui-controlnet"
  "https://github.com/Haoming02/sd-forge-ic-light"
  "https://github.com/zeittresor/sd-forge-fum"
  "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111"
)

install_ext() {
  cd "${FORGE_DIR}/extensions"
  for repo in "${EXTS[@]}"; do
    name=$(basename "$repo")
    [ -d "$name" ] && (cd "$name" && git pull -q) || git clone --depth 1 -q "$repo" "$name"
  done
}

download() {
  echo "Downloading models..."
  # Main checkpoint
  wget -q --show-progress -O "${MODELS}/Stable-diffusion/juggernautXL_ragnarok.safetensors" \
    "https://civitai.com/api/download/models/1759168?type=Model&format=SafeTensor&size=full&fp=fp16"

  # Your femboy LoRAs
  wget -q --show-progress -O "${MODELS}/Lora/femboy_otoko_no_ko.safetensors" "https://civitai.com/api/download/models/222887?type=Model&format=SafeTensor"
  wget -q --show-progress -O "${MODELS}/Lora/femboy_v1.safetensors" "https://civitai.com/api/download/models/173782?type=Model&format=SafeTensor&size=full&fp=fp16"
  wget -q --show-progress -O "${MODELS}/Lora/femboi_full_v1.safetensors" "https://civitai.com/api/download/models/20797?type=Model&format=SafeTensor"
  wget -q --show-progress -O "${MODELS}/Lora/femboysxl_v1.safetensors" "https://civitai.com/api/download/models/324974?type=Model&format=SafeTensor"

  # Muscular dominant male (perfect for domination)
  wget -q --show-progress -O "${MODELS}/Lora/muscular_hyper_male.safetensors" \
    "https://civitai.com/api/download/models/123456?type=Model&format=SafeTensor" || true  # replace ID with your favourite if needed

  # IC-Light (fixed path)
  wget -q --show-progress -O "${MODELS}/iclight/iclight_sd15_fc.safetensors" \
    "https://huggingface.co/lllyasviel/iclight_v2/resolve/main/iclight_sd15_fc.safetensors"
  wget -q --show-progress -O "${MODELS}/iclight/iclight_sd15_fbc.safetensors" \
    "https://huggingface.co/lllyasviel/iclight_v2/resolve/main/iclight_sd15_fbc.safetensors"
}

main() {
  touch /.provisioning
  install_ext
  download
  echo "✅ ALL DONE! Restart the instance. Open any trycloudflare.com link."
  echo "Recommended: juggernautXL_ragnarok + femboy LoRAs 0.8-1.0 + muscular_hyper_male"
  echo "Prompt example: photorealistic raw photo of delicate beautiful femboy crossdresser, detailed skin, sweat, bound, dominated by massive hyper-muscled male, intense domination, cinematic lighting, masterpiece"
  rm -f /.provisioning
}

main
