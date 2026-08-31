#!/usr/bin/env bash
# stop.sh — best-effort cleanup of vLLM and cloudflared processes.
set -uo pipefail

for name in vllm cloudflared; do
  pidfile="state/${name}.pid"
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
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
pkill -f 'cloudflared tunnel' 2>/dev/null || true

echo "stop.sh: cleanup done"
exit 0
