#!/usr/bin/env bash
# serve-mlx.sh — start an MLX OpenAI-compatible server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export BACKEND_PORT=8001
export LOG_FILE="mlx.log"
export PID_FILE="state/mlx.pid"

# shellcheck source=serve-common.sh
source "${SCRIPT_DIR}/serve-common.sh"

: "${ENGINE_VERSION:?ENGINE_VERSION is required}"

apply_model_env

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-/tmp/hf-cache}"
mkdir -p "$HF_HOME"

echo "::group::Install mlx-lm"
echo "creating virtualenv at .venv"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install "mlx-lm" "huggingface_hub[hf_transfer]"
echo "::endgroup::"

echo "::group::Start MLX server"
echo "model:  ${HF_REPO}"
echo "served: ${SERVED_MODEL_NAME}"
echo "backend: mlx_lm.server (port ${BACKEND_PORT})"
nohup python3 -m mlx_lm.server \
  --model "${HF_REPO}" \
  --host 127.0.0.1 \
  --port "${BACKEND_PORT}" \
  > "${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"
echo "server pid: $(cat "${PID_FILE}")"
echo "::endgroup::"

wait_for_backend /health /v1/models
start_landing_proxy
run_warmup

echo "serve-mlx.sh: backend + landing proxy are up."
