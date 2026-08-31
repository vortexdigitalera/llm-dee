#!/usr/bin/env bash
# probe.sh — external health probe through the public tunnel URL.
#
# Usage: ENDPOINT_URL=https://xxx.trycloudflare.com ./scripts/probe.sh
# Optional: LLM_API_KEY, SERVED_MODEL_NAME (default: first from /v1/models)
set -euo pipefail

: "${ENDPOINT_URL:?ENDPOINT_URL is required}"

AUTH=()
if [[ -n "${LLM_API_KEY:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${LLM_API_KEY}")
fi

echo "probing ${ENDPOINT_URL} ..."

# 1) models endpoint
MODELS_JSON="$(curl -fsS --max-time 30 "${ENDPOINT_URL}/v1/models" "${AUTH[@]}")"
echo "models: ${MODELS_JSON}" | head -c 500; echo

MODEL="${SERVED_MODEL_NAME:-$(echo "$MODELS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')}"

# 2) tiny completion
RESP="$(curl -fsS --max-time 120 "${ENDPOINT_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  "${AUTH[@]}" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Reply with the word: ok\"}],
    \"max_tokens\": 4,
    \"temperature\": 0
  }")"

echo "completion: ${RESP}" | head -c 500; echo
echo "probe.sh: OK"
