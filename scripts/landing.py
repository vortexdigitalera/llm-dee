#!/usr/bin/env python3
"""landing.py — tiny front proxy for the LLM endpoint.

Serves on :8000 (the public-facing port the tunnel points at):
  GET /            -> landing page with a live connection-info table + log viewer
  GET /logs        -> plain-text tail of the server log (vllm.log)
  GET /healthz     -> proxy health (200 when backend is up)
  /v1/*            -> reverse-proxied to the MLX/vLLM backend on :8001

This fixes the "url not found" 404 at the root and gives a fast config/access
table plus an external log viewer, without touching the backend server.
"""
from __future__ import annotations

import html
import http.server
import os
import socketserver
import time
import urllib.request
import urllib.error

BACKEND = os.environ.get("BACKEND_URL", "http://127.0.0.1:8001")
PORT = int(os.environ.get("LANDING_PORT", "8000"))
LOG_FILE = os.environ.get("SERVER_LOG", "vllm.log")
MODEL = os.environ.get("SERVED_MODEL_NAME", "model")
HF_REPO = os.environ.get("HF_REPO", "")
PUBLIC_URL = os.environ.get("TUNNEL_PUBLIC_HOSTNAME", "").rstrip("/")
START = time.time()


def _uptime() -> str:
    s = int(time.time() - START)
    return f"{s // 3600}h{(s % 3600) // 60}m{s % 60}s"


def _backend_up() -> bool:
    try:
        with urllib.request.urlopen(f"{BACKEND}/v1/models", timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


LANDING = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>llm-dee endpoint</title>
<style>
 body{{font-family:ui-monospace,Menlo,Consolas,monospace;background:#0b0f14;color:#dbe2ea;margin:0;padding:2rem}}
 h1{{font-size:1.2rem;color:#7ee787;margin:0 0 .25rem}}
 .sub{{color:#8b98a5;font-size:.8rem;margin-bottom:1.5rem}}
 table{{border-collapse:collapse;width:100%;max-width:820px}}
 td,th{{border:1px solid #21262d;padding:.45rem .6rem;font-size:.82rem;text-align:left;vertical-align:top}}
 th{{background:#11161c;color:#9da7b1;width:180px}}
 code{{background:#161b22;padding:.1rem .35rem;border-radius:4px;color:#a5d6ff}}
 .ok{{color:#7ee787}} .bad{{color:#ff7b72}}
 input,button{{font:inherit;padding:.4rem .5rem;background:#0d1117;color:#dbe2ea;border:1px solid #30363d;border-radius:6px}}
 button{{cursor:pointer;background:#1f6feb;border-color:#1f6feb;color:#fff}}
 #log{{white-space:pre-wrap;background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:.8rem;max-height:280px;overflow:auto;font-size:.72rem;margin-top:1rem}}
 .row{{display:flex;gap:.5rem;margin:.4rem 0;flex-wrap:wrap}}
</style></head><body>
<h1>llm-dee &mdash; LLM endpoint</h1>
<div class="sub">OpenAI-compatible API behind a Cloudflare named tunnel</div>

<table>
 <tr><th>Status</th><td>{status}</td></tr>
 <tr><th>Public base URL</th><td><code>{base}</code></td></tr>
 <tr><th>OpenAI API</th><td><code>{base}/v1</code></td></tr>
 <tr><th>Chat completions</th><td><code>POST {base}/v1/chat/completions</code></td></tr>
 <tr><th>Models list</th><td><code>GET {base}/v1/models</code></td></tr>
 <tr><th>Model</th><td><code>{model}</code></td></tr>
 <tr><th>HF repo</th><td><code>{repo}</code></td></tr>
 <tr><th>Uptime</th><td>{uptime}</td></tr>
</table>

<h1 style="margin-top:1.6rem">Quick test</h1>
<div class="row">
 <input id="msg" size="42" value="Say hello in one word">
 <button onclick="send()">Send chat</button>
</div>
<div id="log">response will appear here&hellip;</div>

<h1 style="margin-top:1.6rem">Server log (live tail)</h1>
<div class="row"><button onclick="loadLog()">Refresh log</button>
<label style="font-size:.8rem;color:#8b98a5"><input type="checkbox" id="auto" style="width:auto"> auto-refresh 5s</label></div>
<div id="srvlog">loading&hellip;</div>

<script>
const BASE = location.origin;
async function send(){{
  const box = document.getElementById('log');
  box.textContent = 'waiting...';
  try{{
    const r = await fetch(BASE + '/v1/chat/completions', {{
      method:'POST', headers:{{'Content-Type':'application/json'}},
      body: JSON.stringify({{model:'{model}', messages:[{{role:'user', content: document.getElementById('msg').value}}], max_tokens:64}})
    }});
    const j = await r.json();
    box.textContent = j.choices ? j.choices[0].message.content : JSON.stringify(j,null,2);
  }}catch(e){{ box.textContent = 'error: ' + e; }}
}}
async function loadLog(){{
  try{{ const t = await (await fetch(BASE + '/logs')).text();
    document.getElementById('srvlog').textContent = t; }}catch(e){{}}
}}
loadLog();
setInterval(()=>{{ if(document.getElementById('auto').checked) loadLog(); }}, 5000);
</script>
</body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str = "text/html") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/" or path == "/index.html":
            status = ('<span class="ok">● online</span>' if _backend_up()
                      else '<span class="bad">● backend starting…</span>')
            body = LANDING.format(
                status=status,
                base=html.escape(PUBLIC_URL or f"http://localhost:{PORT}"),
                model=html.escape(MODEL),
                repo=html.escape(HF_REPO),
                uptime=_uptime(),
            ).encode()
            self._send(200, body)
        elif path == "/healthz":
            self._send(200 if _backend_up() else 503, b"ok\n", "text/plain")
        elif path == "/logs":
            try:
                with open(LOG_FILE, "rb") as fh:
                    fh.seek(0, os.SEEK_END)
                    size = fh.tell()
                    fh.seek(max(0, size - 20000))
                    data = fh.read()
                self._send(200, data, "text/plain; charset=utf-8")
            except Exception as e:
                self._send(200, f"(no log yet: {e})".encode(), "text/plain")
        elif path.startswith("/v1/"):
            self._proxy()
        else:
            self._send(404, b"not found\n", "text/plain")

    def do_POST(self):
        if self.path.split("?", 1)[0].startswith("/v1/"):
            self._proxy()
        else:
            self._send(404, b"not found\n", "text/plain")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "content-type,authorization")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()

    def _proxy(self):
        url = BACKEND + self.path
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else None
        req = urllib.request.Request(url, data=data, method=self.command)
        for h in ("Content-Type", "Authorization", "Accept"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self._send(e.code, body, "application/json")
        except Exception as e:
            self._send(502, f'{{"error":"backend unreachable: {e}"}}'.encode(), "application/json")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("0.0.0.0", PORT), Handler) as httpd:
        print(f"landing proxy on :{PORT} -> backend {BACKEND}", flush=True)
        httpd.serve_forever()
