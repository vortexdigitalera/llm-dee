#!/usr/bin/env bash
# serve-vllm.sh — start a vLLM OpenAI-compatible server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export BACKEND_PORT=8001
export LOG_FILE="vllm.log"
export PID_FILE="state/vllm.pid"

# shellcheck source=serve-common.sh
source "${SCRIPT_DIR}/serve-common.sh"

: "${ENGINE_VERSION:?ENGINE_VERSION is required}"
: "${ENGINE_ARGS:?ENGINE_ARGS is required}"

apply_model_env

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-/tmp/hf-cache}"
mkdir -p "$HF_HOME"

echo "::group::Install vLLM ${ENGINE_VERSION}"
echo "creating virtualenv at .venv"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install "vllm==${ENGINE_VERSION}" "huggingface_hub[hf_transfer]"
echo "::endgroup::"

API_KEY_ARGS=()
if [[ -n "${LLM_API_KEY:-}" ]]; then
  API_KEY_ARGS+=(--api-key "$LLM_API_KEY")
  echo "API key auth: enabled"
else
  echo "::warning::LLM_API_KEY secret not set — endpoint will be UNAUTHENTICATED."
fi

echo "::group::Start vLLM server"
echo "model:  ${HF_REPO}"
echo "served: ${SERVED_MODEL_NAME}"
echo "backend: vllm (port ${BACKEND_PORT})"
echo "args:    ${ENGINE_ARGS}"
# shellcheck disable=SC2086
nohup python3 -m vllm.entrypoints.openai.api_server \
  --model "${HF_REPO}" \
  --port "${BACKEND_PORT}" \
  ${ENGINE_ARGS} \
  "${API_KEY_ARGS[@]}" \
  > "${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"
echo "server pid: $(cat "${PID_FILE}")"
echo "::endgroup::"

wait_for_backend /health /v1/models
start_landing_proxy
run_warmup

echo "serve-vllm.sh: backend + landing proxy are up."
