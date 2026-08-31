#!/usr/bin/env bash
# quick_run.sh — one-command quick smoke run of the llm-dee engine.
#
# Two modes:
#   LOCAL  (default when a GPU + this repo are present): resolve -> serve ->
#          tunnel -> print URL, with quick_run settings (skip warmup, 15m TTL).
#   DISPATCH (--dispatch): trigger the GitHub Actions workflow with
#          quick_run=true via the API (needs GH_TOKEN env or git credential).
#
# Usage:
#   ./scripts/quick_run.sh qwen3.8-27b-uncensored fp8      # local quick run
#   ./scripts/quick_run.sh qwen3.8-27b-uncensored          # local, default quant
#   ./scripts/quick_run.sh gemma-4-26b-a4b-it-uncensored fp8 --dispatch
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL_KEY="${1:?usage: quick_run.sh <model_key> [quant] [--dispatch]}"
QUANT="${2:-}"
MODE="local"
for a in "$@"; do [[ "$a" == "--dispatch" ]] && MODE="dispatch"; done
# if QUANT looks like a flag, unset it
[[ "$QUANT" == --* ]] && QUANT=""

if [[ "$MODE" == "dispatch" ]]; then
  REPO="${GITHUB_REPOSITORY:-vortexdigitalera/llm-dee}"
  if [[ -z "${GH_TOKEN:-}" ]]; then
    GH_TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep '^password=' | cut -d= -f2)"
  fi
  body=$(python3 -c '
import json, os
inputs = {"model_key": os.environ["MODEL_KEY"], "quick_run": True}
if os.environ.get("QUANT"):
    inputs["quantization"] = os.environ["QUANT"]
print(json.dumps({"ref": "main", "inputs": inputs}))
' )
  echo "dispatching quick run: ${MODEL_KEY} (${QUANT:-default quant}) on ${REPO}"
  curl -fsS -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/workflows/run-llm.yml/dispatches" \
    -d "$body"
  echo "dispatched. Watch: https://github.com/${REPO}/actions"
  exit 0
fi

# ---- local mode ----
echo "==> resolving ${MODEL_KEY} (${QUANT:-default quant})"
export INPUT_MODEL_KEY="$MODEL_KEY" INPUT_QUANTIZATION="$QUANT"
python3 scripts/resolve_model.py > state_resolve.json
# pull resolved env into this shell
while IFS= read -r line; do export "$line"; done < <(
  python3 -c '
import json
d = json.load(open("state_resolve.json"))
for k in ("HF_REPO","VLLM_VERSION","VLLM_ARGS","MODEL_ENV_JSON","SERVED_MODEL_NAME","RESOLVED_QUANTIZATION"):
    print(f"{k}={d[k]}")
'
)
echo "==> ${HF_REPO} [${RESOLVED_QUANTIZATION}] on vllm ${VLLM_VERSION}"

mkdir -p state
export SKIP_WARMUP=1   # quick run: no warmup
bash scripts/serve.sh
bash scripts/start_tunnel.sh

echo ""
echo "============================================================"
echo "  QUICK RUN endpoint: $(cat state/endpoint_url)"
echo "  OpenAI API:         $(cat state/endpoint_url)/v1"
echo "  Model:              ${SERVED_MODEL_NAME}"
echo "  (Ctrl-C, then run: bash scripts/stop.sh)"
echo "============================================================"
