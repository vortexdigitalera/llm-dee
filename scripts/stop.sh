#!/usr/bin/env bash
# stop.sh — best-effort cleanup of LLM server and cloudflared processes.
# Handles both vLLM/MLX (state/vllm.pid) and Ollama (state/ollama.pid).
set -uo pipefail

for name in vllm ollama landing cloudflared; do
  pidfile="state/${name}.pid"
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if [[ "$pid" == "service" ]]; then
      # named-tunnel service mode: stop and uninstall the service
      echo "stopping ${name} service"
      SUDO=""
      if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi
      if [[ "$(uname -s)" == "Darwin" ]]; then
        $SUDO launchctl stop com.cloudflare.cloudflared 2>/dev/null || true
      else
        $SUDO systemctl stop cloudflared 2>/dev/null || true
      fi
      $SUDO bin/cloudflared service uninstall 2>/dev/null || true
    elif kill -0 "$pid" 2>/dev/null; then
      echo "stopping ${name} (pid ${pid})"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
done

# Belt-and-braces: kill anything still bound to our ports
pkill -f 'vllm.entrypoints.openai.api_server' 2>/dev/null || true
pkill -f 'mlx_lm.server' 2>/dev/null || true
pkill -f 'ollama serve' 2>/dev/null || true
pkill -f 'landing.py' 2>/dev/null || true
pkill -f 'cloudflared tunnel' 2>/dev/null || true

echo "stop.sh: cleanup done"
exit 0
