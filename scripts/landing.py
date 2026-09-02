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

# The backend serves the model under a canonical id:
#   - MLX/vLLM: the HF repo id (rewrite served-name alias -> repo id)
#   - Ollama:   the served-name alias itself (we `ollama create` that name)
# For Ollama, HF_REPO is an hf.co tag the daemon doesn't know, so don't rewrite.
MODEL_ID = MODEL if HF_REPO.startswith("hf.co/") else (HF_REPO or MODEL)


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
<title>llm-dee · LLM endpoint</title>
<style>
 :root{{--bg:#0d1117;--panel:#161b22;--border:#262d36;--fg:#e6edf3;--mut:#8b98a5;
       --acc:#58a6ff;--grn:#3fb950;--red:#f85149;--yel:#d29922;--pur:#bc8cff}}
 *{{box-sizing:border-box}}
 body{{font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
      background:var(--bg);color:var(--fg);margin:0;padding:0}}
 .wrap{{max-width:920px;margin:0 auto;padding:2rem 1.25rem 4rem}}
 header{{display:flex;align-items:center;gap:.7rem;margin-bottom:.25rem}}
 .dot{{width:11px;height:11px;border-radius:50%;background:var(--grn);box-shadow:0 0 10px var(--grn);animation:pulse 2s infinite}}
 .dot.down{{background:var(--yel);box-shadow:0 0 10px var(--yel)}}
 @keyframes pulse{{0%,100%{{opacity:1}}50%{{opacity:.4}}}}
 h1{{font-size:1.25rem;margin:0;font-weight:650;letter-spacing:.2px}}
 .sub{{color:var(--mut);font-size:.83rem;margin-bottom:1.75rem}}
 .card{{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:1.1rem 1.25rem;margin-bottom:1.4rem}}
 .card h2{{font-size:.78rem;text-transform:uppercase;letter-spacing:.12em;color:var(--mut);margin:0 0 .9rem;font-weight:600}}
 table{{border-collapse:collapse;width:100%}}
 td,th{{padding:.5rem .6rem;font-size:.85rem;text-align:left;vertical-align:top;border-bottom:1px solid var(--border)}}
 tr:last-child td,tr:last-child th{{border-bottom:none}}
 th{{color:var(--mut);width:170px;font-weight:500}}
 code{{background:#0d1117;border:1px solid var(--border);padding:.12rem .4rem;border-radius:6px;color:var(--acc);font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.8rem;word-break:break-all}}
 .pill{{font-size:.72rem;padding:.15rem .55rem;border-radius:999px;font-weight:600}}
 .pill.on{{background:rgba(63,185,80,.15);color:var(--grn)}}
 .pill.off{{background:rgba(210,153,34,.15);color:var(--yel)}}
 input,button{{font:inherit;padding:.55rem .7rem;background:#0d1117;color:var(--fg);border:1px solid var(--border);border-radius:8px}}
 input:focus{{outline:none;border-color:var(--acc)}}
 button{{cursor:pointer;background:var(--acc);border-color:var(--acc);color:#04121f;font-weight:600}}
 button.ghost{{background:transparent;color:var(--mut)}}
 button.ghost.on{{color:var(--grn);border-color:var(--grn)}}
 .row{{display:flex;gap:.5rem;margin:.5rem 0;flex-wrap:wrap;align-items:center}}
 #chat{{margin-top:.75rem;padding:.8rem;background:#0d1117;border:1px solid var(--border);border-radius:8px;min-height:3rem;font-size:.9rem;white-space:pre-wrap}}
 /* modern log viewer */
 .logbox{{background:#010409;border:1px solid var(--border);border-radius:10px;overflow:hidden}}
 .logbar{{display:flex;align-items:center;gap:.5rem;padding:.5rem .8rem;background:var(--panel);border-bottom:1px solid var(--border)}}
 .logbar .dot{{width:8px;height:8px}}
 .logbar span{{font-size:.75rem;color:var(--mut)}}
 #srvlog{{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.72rem;line-height:1.55;
         padding:.8rem 1rem;height:340px;overflow-y:auto;white-space:pre-wrap;word-break:break-word}}
 #srvlog .ts{{color:#6e7681}}
 #srvlog .INFO{{color:var(--acc)}} #srvlog .WARN{{color:var(--yel)}}
 #srvlog .ERROR{{color:var(--red)}} #srvlog .GET{{color:var(--pur)}} #srvlog .POST{{color:var(--grn)}}
 #srvlog::-webkit-scrollbar{{width:8px}} #srvlog::-webkit-scrollbar-thumb{{background:var(--border);border-radius:4px}}
</style></head><body>
<div class="wrap">
 <header><span class="dot" id="dot"></span><h1>llm-dee &middot; LLM endpoint</h1></header>
 <div class="sub">OpenAI-compatible API &middot; Cloudflare named tunnel &middot; live for {uptime}</div>

 <div class="card"><h2>Connection</h2>
 <table>
  <tr><th>Status</th><td>{status}</td></tr>
  <tr><th>Landing / logs</th><td><code>{base}/</code> &nbsp;&middot;&nbsp; <code>{base}/logs</code></td></tr>
  <tr><th>OpenAI API base</th><td><code>{base}/v1</code></td></tr>
  <tr><th>Chat completions</th><td><code>POST {base}/v1/chat/completions</code></td></tr>
  <tr><th>Models</th><td><code>GET {base}/v1/models</code></td></tr>
  <tr><th>Model id</th><td><code>{model}</code></td></tr>
  <tr><th>HF repo</th><td><code>{repo}</code></td></tr>
 </table></div>

 <div class="card"><h2>Quick test</h2>
  <div class="row">
   <input id="msg" style="flex:1;min-width:220px" value="Say hello in one word">
   <button onclick="send()">Send</button>
  </div>
  <div id="chat">response will appear here&hellip;</div>
 </div>

 <div class="card"><h2>Live server log</h2>
  <div class="logbox">
   <div class="logbar">
    <span class="dot" id="logdot"></span><span id="logstat">connecting&hellip;</span>
    <span style="flex:1"></span>
    <button class="ghost on" id="follow" onclick="toggleFollow()">follow</button>
    <button class="ghost" onclick="loadLog(true)">refresh</button>
   </div>
   <div id="srvlog"></div>
  </div>
 </div>
</div>

<script>
const BASE = location.origin;
let follow = true;
function toggleFollow(){{ follow=!follow; document.getElementById('follow').classList.toggle('on',follow); }}
async function send(){{
  const box = document.getElementById('chat');
  box.textContent = 'waiting…';
  try{{
    const r = await fetch(BASE + '/v1/chat/completions', {{
      method:'POST', headers:{{'Content-Type':'application/json'}},
      body: JSON.stringify({{model:'{model}', messages:[{{role:'user', content: document.getElementById('msg').value}}], max_tokens:64}})
    }});
    const j = await r.json();
    box.textContent = j.choices ? j.choices[0].message.content : JSON.stringify(j,null,2);
  }}catch(e){{ box.textContent = 'error: ' + e; }}
}}
function colorize(line){{
  let esc = line.replace(/&/g,'&amp;').replace(/</g,'&lt;');
  esc = esc.replace(/(\\d{{4}}-\\d{{2}}-\\d{{2}}[ T]\\d{{2}}:\\d{{2}}:\\d{{2}}[\\d,:-]*)/,'<span class="ts">$1</span>');
  esc = esc.replace(/\\b(INFO)\\b/,'<span class="INFO">$1</span>')
           .replace(/\\b(WARNING|WARN)\\b/,'<span class="WARN">$1</span>')
           .replace(/\\b(ERROR|error|Traceback)\\b/,'<span class="ERROR">$1</span>')
           .replace(/\\b(GET)\\b/,'<span class="GET">$1</span>')
           .replace(/\\b(POST)\\b/,'<span class="POST">$1</span>');
  return esc;
}}
async function loadLog(manual){{
  const el = document.getElementById('srvlog');
  try{{
    const t = await (await fetch(BASE + '/logs')).text();
    el.innerHTML = t.trimEnd().split('\\n').map(colorize).join('\\n');
    document.getElementById('logstat').textContent = 'live · ' + t.split('\\n').length + ' lines';
    document.getElementById('logdot').classList.remove('down');
    if (follow || manual) el.scrollTop = el.scrollHeight;
  }}catch(e){{
    document.getElementById('logstat').textContent = 'log unavailable';
    document.getElementById('logdot').classList.add('down');
  }}
}}
loadLog(true);
setInterval(loadLog, 4000);
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
            status = ('<span class="pill on">online</span>' if _backend_up()
                      else '<span class="pill off">backend starting…</span>')
            body = LANDING.format(
                status=status,
                base=html.escape(PUBLIC_URL or f"http://localhost:{PORT}"),
                model=html.escape(MODEL_ID),
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
        # Rewrite the served-name alias to the backend's real model id (HF repo),
        # so clients can use either name and MLX won't 404 on an unknown repo.
        if data and MODEL_ID and MODEL and MODEL_ID != MODEL:
            try:
                import json as _json
                payload = _json.loads(data)
                if isinstance(payload, dict) and payload.get("model") == MODEL:
                    payload["model"] = MODEL_ID
                    data = _json.dumps(payload).encode()
            except Exception:
                pass
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
