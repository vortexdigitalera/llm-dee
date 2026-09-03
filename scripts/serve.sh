#!/usr/bin/env bash
# serve.sh — thin dispatcher to engine-specific serve scripts.
#
# Required env (produced by resolve_model.py):
#   HF_REPO, ENGINE_VERSION, ENGINE_ARGS, MODEL_ENV_JSON, SERVED_MODEL_NAME, ENGINE
# Optional env:
#   HF_TOKEN            - for gated HF repos
#   LLM_API_KEY         - if set, passed as --api-key (vLLM only)
#   SKIP_WARMUP=1       - skip the warmup completion
#   DEVICE              - cuda | metal | cpu
set -euo pipefail

: "${HF_REPO:?HF_REPO is required}"
: "${ENGINE_VERSION:?ENGINE_VERSION is required}"
: "${ENGINE_ARGS:?ENGINE_ARGS is required}"
: "${MODEL_ENV_JSON:={}}"
: "${SERVED_MODEL_NAME:=model}"
: "${DEVICE:=cuda}"
: "${ENGINE:?ENGINE is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${ENGINE}" in
  vllm)
    exec "${SCRIPT_DIR}/serve-vllm.sh"
    ;;
  mlx)
    exec "${SCRIPT_DIR}/serve-mlx.sh"
    ;;
  ollama)
    exec "${SCRIPT_DIR}/serve-ollama.sh"
    ;;
  *)
    echo "::error::unknown ENGINE='${ENGINE}' (expected vllm|mlx|ollama)"
    exit 1
    ;;
esac
