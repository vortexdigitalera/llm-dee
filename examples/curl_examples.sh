#!/usr/bin/env bash
# curl examples against a running llm-dee endpoint.
set -euo pipefail

: "${LLMDEE_ENDPOINT:?export LLMDEE_ENDPOINT=https://xxxx.trycloudflare.com}"
AUTH=()
[[ -n "${LLMDEE_API_KEY:-}" ]] && AUTH=(-H "Authorization: Bearer ${LLMDEE_API_KEY}")

MODEL="${LLMDEE_MODEL:-$(curl -fsS "${LLMDEE_ENDPOINT}/v1/models" "${AUTH[@]}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"][0]["id"])')}"
echo "model: ${MODEL}"

echo "== chat completion =="
curl -fsS "${LLMDEE_ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" "${AUTH[@]}" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Give me 3 uses for a paperclip\"}],
    \"max_tokens\": 128
  }" | python3 -m json.tool

echo "== streaming =="
curl -fsS -N "${LLMDEE_ENDPOINT}/v1/chat/completions" \
  -H "Content-Type: application/json" "${AUTH[@]}" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 5\"}],
    \"max_tokens\": 32,
    \"stream\": true
  }"

echo
echo "== classic completion =="
curl -fsS "${LLMDEE_ENDPOINT}/v1/completions" \
  -H "Content-Type: application/json" "${AUTH[@]}" \
  -d "{\"model\": \"${MODEL}\", \"prompt\": \"The capital of France is\", \"max_tokens\": 8}" \
  | python3 -m json.tool
