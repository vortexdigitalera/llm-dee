#!/usr/bin/env python3
"""Minimal OpenAI-compatible client for the llm-dee endpoint.

Usage:
    export LLMDEE_ENDPOINT=https://xxxx.trycloudflare.com
    export LLMDEE_API_KEY=...            # if LLM_API_KEY secret was set
    python3 examples/client.py "Explain BGP in one sentence"
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request

ENDPOINT = os.environ.get("LLMDEE_ENDPOINT", "").rstrip("/")
API_KEY = os.environ.get("LLMDEE_API_KEY", "")
MODEL = os.environ.get("LLMDEE_MODEL", "")  # empty = auto-detect


def post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        ENDPOINT + path,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            **({"Authorization": f"Bearer {API_KEY}"} if API_KEY else {}),
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())


def get(path: str) -> dict:
    req = urllib.request.Request(
        ENDPOINT + path,
        headers=({"Authorization": f"Bearer {API_KEY}"} if API_KEY else {}),
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def main() -> None:
    if not ENDPOINT:
        sys.exit("set LLMDEE_ENDPOINT first")
    prompt = " ".join(sys.argv[1:]) or "Say hello"

    model = MODEL or get("/v1/models")["data"][0]["id"]
    out = post(
        "/v1/chat/completions",
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.7,
            "max_tokens": 512,
        },
    )
    print(out["choices"][0]["message"]["content"])


if __name__ == "__main__":
    main()
