#!/usr/bin/env python3
"""Provision a Google Colab T4 as a GitHub Actions self-hosted runner via colabapi.

This is the bridge between llm-dee and colabapi
(https://github.com/vortexdigitalera/colabapi). It:

  1. ensures a Colab T4 runtime is up (starts one with `colabapi run` if not),
  2. health-checks it; if down/expired, stops the stale session and starts fresh,
  3. registers the runtime as a GitHub Actions self-hosted runner (ephemeral),
  4. starts the runner agent inside the Colab VM,
  5. verifies the runner shows up online in the repo.

Everything that runs *on* the Colab VM is delivered as Python through
`colab exec` (colabapi's `exec_code`), because `colab exec` is a Python
executor, not a shell. Shell commands are run via Python's subprocess.

Requirements (on the machine running this script):
  - colabapi installed and signed in (`colabapi login`) — browser OAuth, one time
  - env GH_TOKEN (or GITHUB_TOKEN) with `repo` scope, to mint runner tokens
  - env GITHUB_REPOSITORY (e.g. "vortexdigitalera/llm-dee")

Usage:
  python3 scripts/colab_runner.py up            # ensure runner is up + online
  python3 scripts/colab_runner.py status        # print health + runner state
  python3 scripts/colab_runner.py heal          # if down/expired -> recreate
  python3 scripts/colab_runner.py down          # remove runner + stop session
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
import urllib.request

REPO = os.environ.get("GITHUB_REPOSITORY", "vortexdigitalera/llm-dee")
GH_TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
RUNTIME = os.environ.get("COLAB_RUNTIME", "t4")
SESSION = os.environ.get("COLAB_SESSION", "llm-dee-runner")
RUNNER_LABELS = os.environ.get("COLAB_RUNNER_LABELS", "self-hosted,linux,x64,gpu,t4,colab")
RUNNER_NAME = os.environ.get("COLAB_RUNNER_NAME", "colab-t4")
RUNNER_DIR = os.environ.get("COLAB_RUNNER_DIR", "/content/actions-runner")
RUNNER_VER = os.environ.get("COLAB_RUNNER_VER", "2.328.0")


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def log(msg: str) -> None:
    print(f"[colab-runner] {msg}", flush=True)


def sh(args: list[str], timeout: int = 120, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=capture, text=True, timeout=timeout)


def colab_exec(python_code: str, timeout: int = 120) -> tuple[int, str]:
    """Run Python on the Colab runtime via `colab exec` (stdin)."""
    proc = subprocess.run(
        ["colab", "exec", "-s", SESSION],
        input=python_code, capture_output=True, text=True, timeout=timeout,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, out.strip()


def gh_api(path: str, method: str = "GET", body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
    )
    req.add_header("Authorization", f"token {GH_TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b"{}")


# --------------------------------------------------------------------------- #
# colab session lifecycle
# --------------------------------------------------------------------------- #
def session_alive() -> bool:
    """True if the named session answers a trivial exec."""
    try:
        code, out = colab_exec("print('ok')", timeout=45)
        return code == 0 and "ok" in out
    except Exception:
        return False


def start_runtime() -> bool:
    """Allocate the Colab runtime (interactive TTY for possible OAuth)."""
    log(f"starting Colab runtime '{SESSION}' ({RUNTIME}) — a browser may open for Google sign-in")
    proc = subprocess.run(
        ["colabapi", "run", "--runtime", RUNTIME, "--yes"],
        # inherit TTY so Google's OAuth flow works on first run
    )
    return proc.returncode == 0


def stop_runtime() -> None:
    log(f"stopping session '{SESSION}' (if any)")
    subprocess.run(["colabapi", "stop", SESSION], capture_output=True, text=True, timeout=90)


def ensure_runtime() -> bool:
    if session_alive():
        log("runtime is alive")
        return True
    log("runtime not answering — (re)starting")
    stop_runtime()
    return start_runtime() and session_alive()


# --------------------------------------------------------------------------- #
# github runner registration
# --------------------------------------------------------------------------- #
def registration_token() -> str:
    d = gh_api(f"/repos/{REPO}/actions/runners/registration-token", "POST", {})
    return d["token"]


def remove_runner_if_present() -> None:
    runners = gh_api(f"/repos/{REPO}/actions/runners").get("runners", [])
    for r in runners:
        if r.get("name") == RUNNER_NAME:
            log(f"removing stale runner registration '{RUNNER_NAME}' (id {r['id']})")
            gh_api(f"/repos/{REPO}/actions/runners/{r['id']}", "DELETE")


def runner_online() -> bool:
    runners = gh_api(f"/repos/{REPO}/actions/runners").get("runners", [])
    for r in runners:
        if r.get("name") == RUNNER_NAME:
            return r.get("status") == "online"
    return False


# --------------------------------------------------------------------------- #
# remote (on-VM) runner setup — delivered as Python via colab exec
# --------------------------------------------------------------------------- #
def remote_bootstrap(token: str) -> bool:
    """Download, configure and start the GH runner agent on the Colab VM."""
    py = f"""
import os, subprocess, urllib.request, tarfile, sys

RUNNER_DIR = {RUNNER_DIR!r}
RUNNER_VER = {RUNNER_VER!r}
REPO = {REPO!r}
TOKEN = {token!r}
NAME = {RUNNER_NAME!r}
LABELS = {RUNNER_LABELS!r}
URL = f"https://github.com/actions/runner/releases/download/v{{RUNNER_VER}}/actions-runner-linux-x64-{{RUNNER_VER}}.tar.gz"

os.makedirs(RUNNER_DIR, exist_ok=True)
tgz = os.path.join(RUNNER_DIR, "runner.tar.gz")
if not os.path.exists(os.path.join(RUNNER_DIR, "config.sh")):
    print("downloading runner ...")
    urllib.request.urlretrieve(URL, tgz)
    with tarfile.open(tgz) as t:
        t.extractall(RUNNER_DIR)
    print("extracted")

env = dict(os.environ, RUNNER_ALLOW_RUNASROOT="1")
cfg = [os.path.join(RUNNER_DIR, "config.sh"),
       "--url", f"https://github.com/{{REPO}}",
       "--token", TOKEN,
       "--name", NAME,
       "--labels", LABELS,
       "--runnergroup", "Default",
       "--work", "_work",
       "--ephemeral",
       "--unattended", "--replace"]
print("configuring runner ...")
r = subprocess.run(cfg, cwd=RUNNER_DIR, env=env, capture_output=True, text=True)
print(r.stdout[-2000:]); print(r.stderr[-2000:], file=sys.stderr)
if r.returncode != 0:
    print("CONFIG_FAILED"); sys.exit(1)

# start the agent detached
print("starting runner agent ...")
subprocess.Popen(["nohup", os.path.join(RUNNER_DIR, "run.sh")],
                 cwd=RUNNER_DIR, env=env,
                 stdout=open(os.path.join(RUNNER_DIR, "runner.log"), "ab"),
                 stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print("RUNNER_STARTED")
"""
    code, out = colab_exec(py, timeout=300)
    log(out[-1500:] if out else f"(exit {code})")
    return code == 0 and "RUNNER_STARTED" in out


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_up() -> int:
    if not GH_TOKEN:
        log("ERROR: set GH_TOKEN (repo scope)"); return 1
    if not ensure_runtime():
        log("ERROR: could not bring up Colab runtime"); return 1
    remove_runner_if_present()
    token = registration_token()
    if not remote_bootstrap(token):
        log("ERROR: remote bootstrap failed"); return 1
    # wait for online
    for _ in range(24):
        if runner_online():
            log(f"runner '{RUNNER_NAME}' is ONLINE with labels {RUNNER_LABELS}")
            return 0
        time.sleep(5)
    log("WARNING: runner did not report online within 2 min (check runner.log on the VM)")
    return 1


def cmd_status() -> int:
    alive = session_alive()
    online = runner_online() if GH_TOKEN else False
    log(f"session '{SESSION}' alive: {alive}")
    log(f"runner  '{RUNNER_NAME}' online: {online}")
    return 0 if (alive and online) else 1


def cmd_heal() -> int:
    if session_alive() and runner_online():
        log("healthy — nothing to do")
        return 0
    log("unhealthy — healing (recreate runner)")
    return cmd_up()


def cmd_down() -> int:
    if GH_TOKEN:
        remove_runner_if_present()
    stop_runtime()
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "up"
    return {
        "up": cmd_up,
        "status": cmd_status,
        "heal": cmd_heal,
        "down": cmd_down,
    }.get(cmd, lambda: (log(f"unknown command {cmd}"), 2)[1])()


if __name__ == "__main__":
    sys.exit(main())
