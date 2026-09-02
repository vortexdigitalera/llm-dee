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

# --- engine selection -------------------------------------------------------
# ENGINE comes from the model catalog (vllm | mlx | ollama). Falls back by device.
#   vllm   -> vLLM (OpenAI-compatible server) on CUDA
#   mlx    -> mlx_lm.server on Apple Silicon
#   ollama -> Ollama server (pulls GGUF, serves OpenAI-compatible /v1)
ENGINE="${ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  if [[ "$DEVICE" == "metal" ]]; then
    ENGINE="mlx"
  else
    ENGINE="vllm"
  fi
fi

# --- accelerator guard: never deploy on plain CPU ---------------------------
# DEVICE comes from detect_accel.sh (cuda | metal | cpu).
#   cuda  -> vLLM (OpenAI-compatible server)
#   metal -> MLX (mlx-lm) or Ollama — vLLM publishes no Apple-Silicon wheel.
#   cpu   -> allowed only for Ollama GGUF.
if [[ "$DEVICE" == "metal" ]]; then
  echo "device: Apple Metal (macOS) — engine: ${ENGINE}"
elif [[ "$DEVICE" == "cpu" ]]; then
  if [[ "$ENGINE" == "ollama" ]]; then
    echo "device: CPU — engine: ollama (GGUF)"
  else
    echo "::error::CPU deployment is only supported with ENGINE=ollama."
    exit 1
  fi
elif [[ "$DEVICE" != "cuda" ]]; then
  echo "::error::unknown DEVICE='$DEVICE' (expected cuda|metal|cpu)."
  exit 1
fi

if [[ "$ENGINE" == "ollama" && "$DEVICE" == "cuda" ]]; then
  echo "::warning::Ollama engine selected on CUDA; continuing, but vllm is usually preferred on NVIDIA."
fi

echo "::group::Install serving backend"
# macOS system Python is externally-managed (PEP 668) — always use a virtualenv
# on the Metal path. On CUDA runners a venv is harmless and keeps things uniform.
echo "creating virtualenv at .venv"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 -m pip install --upgrade pip
if [[ "$ENGINE" == "ollama" ]]; then
  # Ollama is installed as a system service; ensure the CLI is available.
  if ! command -v ollama >/dev/null 2>&1; then
    echo "::group::Install Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
    echo "::endgroup::"
  fi
elif [[ "$DEVICE" == "metal" ]]; then
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

# Backend serves on 8001; the landing/log-viewer proxy faces the public on 8000.
BACKEND_PORT=8001

if [[ "$ENGINE" == "ollama" ]]; then
  # Ollama OpenAI-compatible server. HF_REPO is expected to be an Ollama tag
  # (e.g. hf.co/orcarouter/Qwen3.8-27B-Uncensored-GGUF:Qwen3.8-27B-Uncensored-IQ2_XXS).
  # Start the daemon if it isn't running, pull the model, then create a model
  # alias under the served name so /v1/models reports the friendly id.
  echo "backend: ollama (port ${BACKEND_PORT})"
  echo "ollama tag: ${HF_REPO}"

  # Make sure the daemon is listening on the backend port.
  export OLLAMA_HOST="127.0.0.1:${BACKEND_PORT}"
  if ! curl -fsS "http://${OLLAMA_HOST}" >/dev/null 2>&1; then
    echo "starting ollama daemon on ${OLLAMA_HOST}"
    nohup ollama serve > vllm.log 2>&1 &
    echo $! > state/vllm.pid
    for i in $(seq 1 60); do
      if curl -fsS "http://${OLLAMA_HOST}" >/dev/null 2>&1; then
        echo "ollama daemon ready after ${i}s"; break
      fi
      sleep 1
    done
  fi

  # Ollama's `hf.co` pull fails on gated repos (HF redirects to huggingface.co
  # auth realm and Ollama rejects the host mismatch). Download the GGUF blob
  # directly with huggingface_hub (handles HF_TOKEN auth), then `ollama create`
  # from a local Modelfile pointing at the file.
  # HF_REPO format: hf.co/<org>/<repo>:<filename>
  GGUF_FILE="${HF_REPO##*:}"
  HF_GGUF_REPO="${HF_REPO#hf.co/}"; HF_GGUF_REPO="${HF_GGUF_REPO%%:*}"
  echo "downloading ${GGUF_FILE} from ${HF_GGUF_REPO} via huggingface_hub ..."
  python3 -m pip install --quiet "huggingface_hub[hf_transfer]"
  GGUF_PATH="$(python3 - "$HF_GGUF_REPO" "$GGUF_FILE" <<'PY'
import sys
from huggingface_hub import hf_hub_download
print(hf_hub_download(sys.argv[1], sys.argv[2]))
PY
)"
  echo "downloaded to ${GGUF_PATH}"

  # Create a Modelfile from the local GGUF blob.
  MODEL_ALIAS_DIR="${HF_HOME}/ollama-aliases"
  mkdir -p "${MODEL_ALIAS_DIR}"
  cat > "${MODEL_ALIAS_DIR}/${SERVED_MODEL_NAME}.modelfile" <<EOF
FROM ${GGUF_PATH}
EOF
  ollama create "${SERVED_MODEL_NAME}" -f "${MODEL_ALIAS_DIR}/${SERVED_MODEL_NAME}.modelfile" 2>&1 | tee -a vllm.log

  # Ollama already exposes /v1 on its own port; nothing else to start.
  # Record the daemon pid for keep-alive checks.
  pgrep -f 'ollama serve' > state/vllm.pid || true

elif [[ "$ENGINE" == "mlx" ]]; then
  # MLX OpenAI-compatible server. It does not understand vLLM args; pass only
  # what it supports.
  echo "backend: mlx_lm.server (port ${BACKEND_PORT})"
  nohup python3 -m mlx_lm.server \
    --model "${HF_REPO}" \
    --host 127.0.0.1 \
    --port "${BACKEND_PORT}" \
    > vllm.log 2>&1 &
  echo $! > state/vllm.pid
else
  echo "backend: vLLM (port ${BACKEND_PORT})"
  echo "args:    ${VLLM_ARGS}"
  # shellcheck disable=SC2086
  nohup python3 -m vllm.entrypoints.openai.api_server \
    --model "${HF_REPO}" \
    --port "${BACKEND_PORT}" \
    ${VLLM_ARGS} \
    "${API_KEY_ARGS[@]}" \
    > vllm.log 2>&1 &
  echo $! > state/vllm.pid
fi
echo "server pid: $(cat state/vllm.pid)"
echo "::endgroup::"

echo "Waiting for backend /health on :${BACKEND_PORT} ..."
for i in $(seq 1 240); do
  if curl -fsS "http://127.0.0.1:${BACKEND_PORT}/health" >/dev/null 2>&1 \
     || curl -fsS "http://127.0.0.1:${BACKEND_PORT}/v1/models" >/dev/null 2>&1; then
    echo "backend is healthy after ~$((i * 5))s"
    break
  fi
  if [[ "$ENGINE" != "ollama" ]] && ! kill -0 "$(cat state/vllm.pid)" 2>/dev/null; then
    echo "::error::vLLM/MLX process died — last 200 log lines:"
    tail -n 200 vllm.log || true
    exit 1
  fi
  if [[ "$i" == "240" ]]; then
    echo "::error::backend did not become healthy within 20 minutes"
    tail -n 200 vllm.log || true
    exit 1
  fi
  sleep 5
done

# --- Landing / log-viewer proxy on the public port 8000 ----------------------
echo "::group::Start landing proxy (:8000 -> :${BACKEND_PORT})"
BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}" \
LANDING_PORT=8000 \
SERVER_LOG=vllm.log \
SERVED_MODEL_NAME="${SERVED_MODEL_NAME}" \
HF_REPO="${HF_REPO}" \
  nohup python3 scripts/landing.py > landing.log 2>&1 &
echo $! > state/landing.pid
echo "landing pid: $(cat state/landing.pid)"
# wait for the proxy to answer
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
    echo "landing proxy up after ~${i}s"; break
  fi
  sleep 1
done
echo "::endgroup::"

# --- Prompt test after start --------------------------------------------------
if [[ "${SKIP_WARMUP:-0}" != "1" ]]; then
  echo "::group::Prompt test (through landing proxy :8000)"
  AUTH_HEADER=()
  if [[ -n "${LLM_API_KEY:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${LLM_API_KEY}")
  fi
  for attempt in 1 2 3 4 5; do
    if RESP="$(curl -fsS --max-time 120 http://127.0.0.1:8000/v1/chat/completions \
      -H "Content-Type: application/json" \
      ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
      -d "{
        \"model\": \"${SERVED_MODEL_NAME}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Say 'ready' and nothing else.\"}],
        \"max_tokens\": 8,
        \"temperature\": 0
      }" 2>/dev/null)"; then
      echo "prompt test response:"
      echo "$RESP" | python3 -m json.tool || echo "$RESP"
      break
    fi
    echo "prompt test attempt ${attempt}/5 not ready — retrying in 10s"
    sleep 10
  done
  echo "::endgroup::"
fi

echo "serve.sh: backend + landing proxy are up."
