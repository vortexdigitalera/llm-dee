#!/usr/bin/env bash
# serve-ollama.sh — start an Ollama server on the standard port 11434.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export BACKEND_PORT=11434
export LOG_FILE="ollama.log"
export PID_FILE="state/ollama.pid"

# shellcheck source=serve-common.sh
source "${SCRIPT_DIR}/serve-common.sh"

apply_model_env

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-/tmp/hf-cache}"
mkdir -p "$HF_HOME"

echo "::group::Install Ollama"
python3 -m pip install --upgrade pip
python3 -m pip install "huggingface_hub[hf_transfer]"
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
echo "::endgroup::"

echo "::group::Start Ollama server"
echo "model:  ${HF_REPO}"
echo "served: ${SERVED_MODEL_NAME}"
echo "backend: ollama (port ${BACKEND_PORT}) — standard Ollama port"
echo "ollama tag: ${HF_REPO}"

export OLLAMA_HOST="127.0.0.1:${BACKEND_PORT}"
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl stop ollama 2>/dev/null || true
fi
pkill -f 'ollama serve' 2>/dev/null || true
sleep 1
echo "starting ollama daemon on ${OLLAMA_HOST} (standard port ${BACKEND_PORT})"
nohup ollama serve > "${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"

for i in $(seq 1 60); do
  if curl -fsS "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    echo "ollama daemon ready after ${i}s"; break
  fi
  if ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "::error::ollama daemon died at startup — last 50 log lines:"
    tail -n 50 "${LOG_FILE}" || true
    exit 1
  fi
  sleep 1
done

# Pull the model. Two formats are supported:
#   1. Native Ollama tag:  orcarouter/Qwen3.8-27B-Uncensored:iq2_xxs
#   2. HF GGUF tag:         hf.co/<org>/<repo>:<file>
if [[ "${HF_REPO}" == hf.co/* ]]; then
  GGUF_FILE="${HF_REPO##*:}"
  HF_GGUF_REPO="${HF_REPO#hf.co/}"; HF_GGUF_REPO="${HF_GGUF_REPO%%:*}"
  if [[ "${GGUF_FILE}" != *.gguf ]]; then
    GGUF_FILE="${GGUF_FILE}.gguf"
  fi
  echo "downloading ${GGUF_FILE} from ${HF_GGUF_REPO} via huggingface_hub ..."
  GGUF_PATH="$(python3 - "$HF_GGUF_REPO" "$GGUF_FILE" <<'PY'
import sys
from huggingface_hub import hf_hub_download
print(hf_hub_download(sys.argv[1], sys.argv[2]))
PY
)"
  echo "downloaded to ${GGUF_PATH}"
  MODEL_ALIAS_DIR="${HF_HOME}/ollama-aliases"
  mkdir -p "${MODEL_ALIAS_DIR}"
  cat > "${MODEL_ALIAS_DIR}/${SERVED_MODEL_NAME}.modelfile" <<EOF
FROM ${GGUF_PATH}
EOF
  ollama create "${SERVED_MODEL_NAME}" -f "${MODEL_ALIAS_DIR}/${SERVED_MODEL_NAME}.modelfile" 2>&1 | tee -a "${LOG_FILE}"
else
  echo "pulling ${HF_REPO} from ollama.com ..."
  ollama pull "${HF_REPO}" 2>&1 | tee -a "${LOG_FILE}"
  MODEL_ALIAS_DIR="${HF_HOME}/ollama-aliases"
  mkdir -p "${MODEL_ALIAS_DIR}"
  cat > "${MODEL_ALIAS_DIR}/${SERVED_MODEL_NAME}.modelfile" <<EOF
FROM ${HF_REPO}
EOF
  ollama create "${SERVED_MODEL_NAME}" -f "${MODEL_ALIAS_DIR}/${SERVED_MODEL_NAME}.modelfile" 2>&1 | tee -a "${LOG_FILE}"
fi
echo "::endgroup::"

wait_for_backend /api/tags /v1/models
start_landing_proxy
run_warmup

echo "serve-ollama.sh: backend + landing proxy are up."
