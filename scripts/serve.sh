#!/usr/bin/env bash
# serve.sh — core engine entrypoint.
#
# Installs vLLM (pinned), applies per-model env, starts the OpenAI-compatible
# server in the background, waits for /health, then runs a warmup request.
#
# Required env (produced by resolve_model.py):
#   HF_REPO, VLLM_VERSION, VLLM_ARGS, MODEL_ENV_JSON, SERVED_MODEL_NAME
# Optional env:
#   HF_TOKEN            - for gated HF repos
#   LLM_API_KEY         - if set, passed as --api-key
#   SKIP_WARMUP=1       - skip the warmup completion
set -euo pipefail

: "${HF_REPO:?HF_REPO is required}"
: "${VLLM_VERSION:?VLLM_VERSION is required}"
: "${VLLM_ARGS:?VLLM_ARGS is required}"
: "${MODEL_ENV_JSON:={}}"
: "${SERVED_MODEL_NAME:=model}"
: "${DEVICE:=cuda}"

# --- accelerator guard: never deploy on plain CPU ---------------------------
# DEVICE comes from detect_accel.sh (cuda | metal).
#   cuda  -> vLLM (OpenAI-compatible server)
#   metal -> MLX (mlx-lm) — vLLM publishes no Apple-Silicon wheel and cannot be
#            built on macOS, so the native Apple backend is MLX. mlx_lm.server
#            exposes an OpenAI-compatible /v1/chat/completions endpoint.
if [[ "$DEVICE" == "metal" ]]; then
  echo "device: Apple Metal (macOS) — MLX backend (mlx-lm)"
elif [[ "$DEVICE" != "cuda" ]]; then
  echo "::error::unknown DEVICE='$DEVICE' (expected cuda|metal). Refusing to deploy on plain CPU."
  exit 1
fi

echo "::group::Install serving backend"
# macOS system Python is externally-managed (PEP 668) — always use a virtualenv
# on the Metal path. On CUDA runners a venv is harmless and keeps things uniform.
echo "creating virtualenv at .venv"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 -m pip install --upgrade pip
if [[ "$DEVICE" == "metal" ]]; then
  python3 -m pip install "mlx-lm" "huggingface_hub[hf_transfer]"
else
  python3 -m pip install "vllm==${VLLM_VERSION}" "huggingface_hub[hf_transfer]"
fi
echo "::endgroup::"

# Apply per-model env from the catalog (e.g. VLLM_USE_V1, trust-remote-code flags)
python3 - <<'PY'
import json, os
for k, v in json.loads(os.environ.get("MODEL_ENV_JSON", "{}")).items():
    os.environ[k] = str(v)
    print(f"env: {k}={v}")
PY

# Export per-model env into this shell as well
while IFS='=' read -r k v; do export "$k=$v"; done < <(
  python3 -c 'import json,os; [print(f"{k}={v}") for k,v in json.loads(os.environ.get("MODEL_ENV_JSON","{}")).items()]'
)

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_HOME="${HF_HOME:-/tmp/hf-cache}"
mkdir -p "$HF_HOME"

API_KEY_ARGS=()
if [[ -n "${LLM_API_KEY:-}" ]]; then
  API_KEY_ARGS+=(--api-key "$LLM_API_KEY")
  echo "API key auth: enabled"
else
  echo "::warning::LLM_API_KEY secret not set — endpoint will be UNAUTHENTICATED."
fi

echo "::group::Start server"
echo "model:  ${HF_REPO}"
echo "served: ${SERVED_MODEL_NAME}"

if [[ "$DEVICE" == "metal" ]]; then
  # MLX OpenAI-compatible server. It does not understand vLLM args; pass only
  # what it supports. Default port 8000 to match the tunnel/probe.
  echo "backend: mlx_lm.server"
  nohup python3 -m mlx_lm.server \
    --model "${HF_REPO}" \
    --host 0.0.0.0 \
    --port 8000 \
    > vllm.log 2>&1 &
else
  echo "backend: vLLM"
  echo "args:    ${VLLM_ARGS}"
  # shellcheck disable=SC2086
  nohup python3 -m vllm.entrypoints.openai.api_server \
    --model "${HF_REPO}" \
    ${VLLM_ARGS} \
    "${API_KEY_ARGS[@]}" \
    > vllm.log 2>&1 &
fi
echo $! > state/vllm.pid
echo "server pid: $(cat state/vllm.pid)"
echo "::endgroup::"

echo "Waiting for vLLM /health ..."
for i in $(seq 1 240); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
    echo "vLLM is healthy after ~$((i * 5))s"
    break
  fi
  if ! kill -0 "$(cat state/vllm.pid)" 2>/dev/null; then
    echo "::error::vLLM process died — last 200 log lines:"
    tail -n 200 vllm.log || true
    exit 1
  fi
  if [[ "$i" == "240" ]]; then
    echo "::error::vLLM did not become healthy within 20 minutes"
    tail -n 200 vllm.log || true
    exit 1
  fi
  sleep 5
done

if [[ "${SKIP_WARMUP:-0}" != "1" ]]; then
  echo "::group::Warmup request"
  AUTH_HEADER=()
  if [[ -n "${LLM_API_KEY:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${LLM_API_KEY}")
  fi
  curl -fsS http://127.0.0.1:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER[@]}" \
    -d "{
      \"model\": \"${SERVED_MODEL_NAME}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say 'ready' and nothing else.\"}],
      \"max_tokens\": 8,
      \"temperature\": 0
    }" | python3 -m json.tool || echo "::warning::warmup request failed (server still up)"
  echo "::endgroup::"
fi

echo "serve.sh: vLLM is up and warm."
