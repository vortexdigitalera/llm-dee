#!/usr/bin/env bash
# warmup_runner.sh — run ONCE on a self-hosted GPU runner to prepare the
# persistent caches that make workflow starts fast.
#
#   sudo ./scripts/warmup_runner.sh
#
# What it does:
#   1. Installs system deps (python3, pip, curl, jq)
#   2. Creates /opt/llm-dee/hf-cache (persistent HF cache across runs)
#   3. Pre-pulls cloudflared
#   4. Optionally pre-downloads a model:  ./scripts/warmup_runner.sh qwen2.5-7b-instruct awq
set -euo pipefail

CACHE_DIR="${LLMDEE_CACHE:-/opt/llm-dee/hf-cache}"

echo "==> system deps"
if command -v apt-get >/dev/null; then
  sudo apt-get update -y
  sudo apt-get install -y python3 python3-pip python3-venv curl jq
fi

echo "==> persistent HF cache at ${CACHE_DIR}"
sudo mkdir -p "$CACHE_DIR"
sudo chown -R "$USER":"$USER" "$CACHE_DIR"

echo "==> cloudflared"
mkdir -p bin
ARCH="$(uname -m)"; [[ "$ARCH" == "x86_64" ]] && CF_ARCH=amd64 || CF_ARCH=arm64
curl -fsSL -o bin/cloudflared \
  "https://github.com/cloudflare/cloudflared/releases/download/2024.12.2/cloudflared-linux-${CF_ARCH}"
chmod +x bin/cloudflared

if [[ $# -ge 1 ]]; then
  MODEL_KEY="$1"; QUANT="${2:-}"
  echo "==> pre-downloading ${MODEL_KEY} (${QUANT:-default})"
  INPUT_MODEL_KEY="$MODEL_KEY" INPUT_QUANTIZATION="$QUANT" \
    python3 scripts/resolve_model.py > /tmp/llmdee-resolve.json
  HF_REPO="$(python3 -c 'import json;print(json.load(open("/tmp/llmdee-resolve.json"))["HF_REPO"])')"
  python3 -m pip install "huggingface_hub[hf_transfer]"
  HF_HOME="$CACHE_DIR" HF_HUB_ENABLE_HF_TRANSFER=1 \
    python3 -c "from huggingface_hub import snapshot_download; snapshot_download('${HF_REPO}')"
  echo "==> cached ${HF_REPO}"
fi

echo "warmup_runner.sh: done. Point HF_HOME at ${CACHE_DIR} in your runner env for warm starts."
