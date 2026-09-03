#!/usr/bin/env bash
# probe.sh — external health probe through the public tunnel URL.
#
# Usage: ENDPOINT_URL=https://xxx.trycloudflare.com ENGINE=ollama ./scripts/probe.sh
# Optional: LLM_API_KEY, SERVED_MODEL_NAME (default: first from /v1/models)
set -euo pipefail

: "${ENDPOINT_URL:?ENDPOINT_URL is required}"

ENGINE="${ENGINE:-vllm}"
AUTH=()
if [[ -n "${LLM_API_KEY:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${LLM_API_KEY}")
fi

echo "probing ${ENDPOINT_URL} (engine: ${ENGINE}) ..."

# 1) Wait for the public origin to answer
MODELS_JSON=""
for i in $(seq 1 30); do
  if MODELS_JSON="$(curl -fsS --max-time 30 "${ENDPOINT_URL}/v1/models" ${AUTH[@]+"${AUTH[@]}"} 2>/dev/null)"; then
    break
  fi
  echo "origin not ready yet (attempt ${i}/30) — retrying in 5s"
  sleep 5
done
if [[ -z "$MODELS_JSON" ]]; then
  echo "::error::origin never became reachable at ${ENDPOINT_URL}"
  exit 1
fi
echo "models: ${MODELS_JSON}" | head -c 500; echo

MODEL="${SERVED_MODEL_NAME:-$(echo "$MODELS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')}"

# 2) Engine-specific generation probe
RESP=""
if [[ "$ENGINE" == "ollama" ]]; then
  # Probe Ollama native /api/chat (also validates tool-calling path shape)
  for i in $(seq 1 10); do
    if RESP="$(curl -fsS --max-time 120 "${ENDPOINT_URL}/api/chat" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Reply with the word: ok\"}],
        \"stream\": false
      }" 2>/dev/null)"; then
      break
    fi
    echo "ollama /api/chat not ready yet (attempt ${i}/10) — retrying in 10s"
    sleep 10
  done
else
  for i in $(seq 1 10); do
    if RESP="$(curl -fsS --max-time 120 "${ENDPOINT_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      ${AUTH[@]+"${AUTH[@]}"} \
      -d "{
        \"model\": \"${MODEL}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Reply with the word: ok\"}],
        \"max_tokens\": 4,
        \"temperature\": 0
      }" 2>/dev/null)"; then
      break
    fi
    echo "completion not ready yet (attempt ${i}/10) — retrying in 10s"
    sleep 10
  done
fi

if [[ -z "$RESP" ]]; then
  echo "::error::generation probe never succeeded at ${ENDPOINT_URL}"
  exit 1
fi

echo "generation: ${RESP}" | head -c 500; echo
echo "probe.sh: OK"

