#!/usr/bin/env bash
# start_tunnel.sh — start a Cloudflare QUICK tunnel (no Argo, no account).
#
# Downloads a pinned cloudflared, starts it against http://localhost:8000,
# scrapes the ephemeral https://<random>.trycloudflare.com URL from the log
# and publishes it:
#   - appends to $GITHUB_STEP_SUMMARY (if set)
#   - writes `endpoint_url` to $GITHUB_OUTPUT (if set)
#   - writes state/endpoint_url
#
# Optional env:
#   CLOUDFLARED_VERSION - default 2024.12.2
set -euo pipefail

CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2024.12.2}"
OS="$(uname -s)"
ARCH="$(uname -m)"

# Map to cloudflared release asset names. Linux ships a bare binary; macOS
# (Darwin) ships a .tgz containing the binary.
case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64)        CF_ASSET="cloudflared-linux-amd64" ;;
      aarch64|arm64) CF_ASSET="cloudflared-linux-arm64" ;;
      *) echo "::error::unsupported Linux arch: $ARCH"; exit 1 ;;
    esac
    CF_TGZ=0
    ;;
  Darwin)
    case "$ARCH" in
      x86_64) CF_ASSET="cloudflared-darwin-amd64.tgz" ;;
      arm64)  CF_ASSET="cloudflared-darwin-arm64.tgz" ;;
      *) echo "::error::unsupported macOS arch: $ARCH"; exit 1 ;;
    esac
    CF_TGZ=1
    ;;
  *) echo "::error::unsupported OS: $OS"; exit 1 ;;
esac

mkdir -p state bin

if [[ ! -x bin/cloudflared ]]; then
  echo "::group::Download cloudflared ${CLOUDFLARED_VERSION} (${OS}/${ARCH})"
  url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${CF_ASSET}"
  if [[ "$CF_TGZ" == "1" ]]; then
    curl -fsSL "$url" | tar -xz -C bin
  else
    curl -fsSL -o bin/cloudflared "$url"
  fi
  chmod +x bin/cloudflared
  bin/cloudflared --version
  echo "::endgroup::"
fi

# --- Named tunnel (service) mode ---------------------------------------------
# If CLOUDFLARE_TUNNEL_TOKEN is set, install cloudflared as a system service
# using the named-tunnel token and start it. The public hostname and routing
# are controlled from the Cloudflare Zero Trust dashboard (no trycloudflare URL
# is scraped in this mode).
if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
  echo "::group::Install & start cloudflared service (named tunnel)"
  SUDO=""
  if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

  # Install the service with the token, then start it.
  $SUDO bin/cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # launchd
    $SUDO launchctl start com.cloudflare.cloudflared || true
  else
    # systemd
    $SUDO systemctl enable cloudflared || true
    $SUDO systemctl restart cloudflared
  fi

  # The service runs detached; record a sentinel pid for the keep-alive check.
  # We poll the service instead of a foreground process.
  echo "service" > state/cloudflared.pid
  echo "named tunnel service installed and started"
  echo "::endgroup::"

  ENDPOINT_URL="${TUNNEL_PUBLIC_HOSTNAME:-see Cloudflare Zero Trust dashboard -> Networks -> Tunnels}"
  echo "$ENDPOINT_URL" > state/endpoint_url
  echo "Endpoint: ${ENDPOINT_URL}"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "endpoint_url=${ENDPOINT_URL}" >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo ""
      echo "## Named tunnel (service mode)"
      echo ""
      echo "cloudflared installed as a system service with the named-tunnel token."
      echo "Manage the public hostname and ingress rules in the Cloudflare Zero Trust"
      echo "dashboard (**Networks → Tunnels**). Point your hostname at \`http://localhost:8000\`."
      echo ""
      if [[ -n "${TUNNEL_PUBLIC_HOSTNAME:-}" ]]; then
        echo "| **Base URL** | \`${TUNNEL_PUBLIC_HOSTNAME}\` |"
        echo "| **OpenAI API** | \`${TUNNEL_PUBLIC_HOSTNAME}/v1\` |"
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

echo "::group::Start quick tunnel"
nohup bin/cloudflared tunnel \
  --no-autoupdate \
  --loglevel info \
  --metrics 127.0.0.1:20000 \
  --url http://localhost:8000 \
  > cloudflared.log 2>&1 &
echo $! > state/cloudflared.pid
echo "cloudflared pid: $(cat state/cloudflared.pid)"
echo "::endgroup::"

echo "Waiting for trycloudflare URL ..."
ENDPOINT_URL=""
for i in $(seq 1 60); do
  ENDPOINT_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)"
  if [[ -n "$ENDPOINT_URL" ]]; then
    break
  fi
  if ! kill -0 "$(cat state/cloudflared.pid)" 2>/dev/null; then
    echo "::error::cloudflared died — log:"
    cat cloudflared.log || true
    exit 1
  fi
  sleep 2
done

if [[ -z "$ENDPOINT_URL" ]]; then
  echo "::error::could not find trycloudflare URL in cloudflared.log"
  cat cloudflared.log || true
  exit 1
fi

echo "$ENDPOINT_URL" > state/endpoint_url
echo "Endpoint: ${ENDPOINT_URL}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "endpoint_url=${ENDPOINT_URL}" >> "$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo ""
    echo "## Public endpoint"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| **Base URL** | \`${ENDPOINT_URL}\` |"
    echo "| **OpenAI API** | \`${ENDPOINT_URL}/v1\` |"
    echo "| **Model** | \`${SERVED_MODEL_NAME:-unknown}\` |"
    echo "| **HF repo** | \`${HF_REPO:-unknown}\` |"
    echo "| **Quantization** | \`${RESOLVED_QUANTIZATION:-unknown}\` |"
    echo ""
    if [[ -n "${LLM_API_KEY:-}" ]]; then
      echo "> Auth: send header \`Authorization: Bearer \$LLM_API_KEY\`"
    else
      echo "> ⚠️ No \`LLM_API_KEY\` secret set — endpoint is public and unauthenticated."
    fi
    echo ""
    echo '```bash'
    echo "curl ${ENDPOINT_URL}/v1/chat/completions \\"
    echo '  -H "Content-Type: application/json" \'
    if [[ -n "${LLM_API_KEY:-}" ]]; then
      echo '  -H "Authorization: Bearer $LLM_API_KEY" \'
    fi
    echo "  -d '{\"model\": \"${SERVED_MODEL_NAME:-model}\", \"messages\": [{\"role\": \"user\", \"content\": \"hello\"}]}'"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "start_tunnel.sh: tunnel up at ${ENDPOINT_URL}"
