#!/usr/bin/env bash
# serve-common.sh — shared helpers for engine-specific serve scripts.
# Sourced by serve-vllm.sh, serve-ollama.sh, serve-mlx.sh.
set -euo pipefail

# --- common env defaults -----------------------------------------------------
: "${HF_REPO:?HF_REPO is required}"
: "${SERVED_MODEL_NAME:=model}"
: "${DEVICE:=cuda}"
: "${ENGINE:?ENGINE is required}"
: "${MODEL_ENV_JSON:={}}"
: "${BACKEND_PORT:?BACKEND_PORT is required}"
: "${LOG_FILE:?LOG_FILE is required}"
: "${PID_FILE:?PID_FILE is required}"

mkdir -p state

# Apply per-model env from the catalog (e.g. VLLM_USE_V1, trust-remote-code flags)
apply_model_env() {
  python3 - <<'PY'
import json, os
for k, v in json.loads(os.environ.get("MODEL_ENV_JSON", "{}")).items():
    os.environ[k] = str(v)
    print(f"env: {k}={v}")
PY
  while IFS='=' read -r k v; do export "$k=$v"; done < <(
    python3 -c 'import json,os; [print(f"{k}={v}") for k,v in json.loads(os.environ.get("MODEL_ENV_JSON","{}")).items()]'
  )
}

# Start the landing proxy on :8000 -> backend :${BACKEND_PORT}
start_landing_proxy() {
  echo "::group::Start landing proxy (:8000 -> :${BACKEND_PORT})"
  BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}" \
  LANDING_PORT=8000 \
  SERVER_LOG="${LOG_FILE}" \
  SERVED_MODEL_NAME="${SERVED_MODEL_NAME}" \
  HF_REPO="${HF_REPO}" \
  ENGINE="${ENGINE}" \
    nohup python3 scripts/landing.py > landing.log 2>&1 &
  echo $! > state/landing.pid
  echo "landing pid: $(cat state/landing.pid)"
  for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
      echo "landing proxy up after ~${i}s"; break
    fi
    sleep 1
  done
  echo "::endgroup::"
}

# Wait for backend health endpoint(s)
wait_for_backend() {
  local -a health_urls=("$@")
  echo "Waiting for backend health on :${BACKEND_PORT} ..."
  for i in $(seq 1 240); do
    for url in "${health_urls[@]}"; do
      if curl -fsS "http://127.0.0.1:${BACKEND_PORT}${url}" >/dev/null 2>&1; then
        echo "backend is healthy after ~$((i * 5))s"
        return 0
      fi
    done
    if ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "::error::server process died — last 200 log lines:"
      tail -n 200 "${LOG_FILE}" || true
      exit 1
    fi
    if [[ "$i" == "240" ]]; then
      echo "::error::backend did not become healthy within 20 minutes"
      tail -n 200 "${LOG_FILE}" || true
      exit 1
    fi
    sleep 5
  done
}

# Optional warmup prompt through the landing proxy
run_warmup() {
  if [[ "${SKIP_WARMUP:-0}" == "1" ]]; then
    return 0
  fi
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
}
