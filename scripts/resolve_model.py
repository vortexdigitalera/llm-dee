#!/usr/bin/env python3
"""Resolve a model + quantization from models.json into vLLM launch config.

Reads inputs from environment variables (set by the composite action or by
hand) and writes results to $GITHUB_OUTPUT and $GITHUB_ENV when present,
falling back to stdout for local use.

Inputs (env):
  INPUT_MODEL_KEY        - key in models.json "models" (required)
  INPUT_QUANTIZATION     - requested quantization, "" = catalog default
  INPUT_MAX_MODEL_LEN    - "0" = catalog default
  INPUT_GPU_MEM_UTIL     - "0" = catalog default
  INPUT_EXTRA_ARGS       - extra raw vLLM args appended last
  CATALOG_PATH           - path to models.json (default: repo root)

Outputs:
  GITHUB_ENV:    RUNNER_LABELS_JSON, HF_REPO, VLLM_VERSION, VLLM_ARGS,
                 MODEL_ENV_JSON, SERVED_MODEL_NAME, RESOLVED_QUANTIZATION
  GITHUB_OUTPUT: runner_labels, hf_repo, vllm_version, served_model_name,
                 resolved_quantization
"""
from __future__ import annotations

import json
import os
import shlex
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path(os.environ.get("CATALOG_PATH", REPO_ROOT / "models.json"))


def fail(msg: str) -> "None":
    print(f"::error::resolve_model: {msg}", file=sys.stderr)
    sys.exit(1)


def write_env_file(path: str, values: dict[str, str]) -> None:
    with open(path, "a", encoding="utf-8") as fh:
        for key, val in values.items():
            # heredoc style to survive multiline/special chars
            delim = "EOF_LLMDEE"
            fh.write(f"{key}<<{delim}\n{val}\n{delim}\n")


def main() -> None:
    model_key = os.environ.get("INPUT_MODEL_KEY", "").strip()
    if not model_key:
        fail("INPUT_MODEL_KEY is required")

    if not CATALOG.exists():
        fail(f"catalog not found: {CATALOG}")

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    defaults = catalog.get("defaults", {})
    models = catalog.get("models", {})

    if model_key not in models:
        fail(f"model '{model_key}' not in catalog. Available: {', '.join(sorted(models))}")

    model = models[model_key]
    quants = model.get("quantizations", {})

    requested_quant = os.environ.get("INPUT_QUANTIZATION", "").strip()
    quant_key = requested_quant or model.get("default_quantization", "")
    if quant_key not in quants:
        fail(
            f"quantization '{quant_key}' not available for '{model_key}'. "
            f"Available: {', '.join(sorted(quants))}"
        )
    quant = quants[quant_key]

    hf_repo = quant.get("repo") or model["hf_repo"]
    dtype = quant.get("dtype", model.get("dtype", defaults.get("dtype", "auto")))
    quantization = quant.get("quantization")

    max_len_env = os.environ.get("INPUT_MAX_MODEL_LEN", "0").strip()
    max_model_len = int(max_len_env) if max_len_env not in ("", "0") else int(
        model.get("max_model_len", defaults.get("max_model_len", 8192))
    )

    mem_env = os.environ.get("INPUT_GPU_MEM_UTIL", "0").strip()
    gpu_mem_util = float(mem_env) if mem_env not in ("", "0") else float(
        model.get("gpu_memory_utilization", defaults.get("gpu_memory_utilization", 0.90))
    )

    runner_labels = model.get("runner_labels", defaults.get("runner_labels", ["self-hosted", "gpu"]))
    vllm_version = model.get("vllm_version", defaults.get("vllm_version", "0.6.4.post1"))
    served_name = model.get("served_model_name") or defaults.get("served_model_name") or model_key
    engine = model.get("engine", defaults.get("engine", "")).strip().lower()
    if not engine:
        engine = "mlx" if device == "metal" else "vllm"

    # Device override (cuda | metal | cpu) from detect_accel.sh. On Metal/CPU we
    # force a CPU-friendly dtype and drop GPU-only flags; quantization that needs
    # CUDA kernels (awq/gptq/fp8/nvfp4) is not available there.
    device = os.environ.get("INPUT_DEVICE", "").strip().lower()
    if device in ("metal", "cpu"):
        dtype = "float16"
        if engine != "ollama" and quantization and quantization not in ("none", ""):
            print(
                f"::warning::quantization '{quantization}' needs CUDA kernels; "
                "ignoring it on CPU/Metal (using unquantized fp16 weights).",
                file=sys.stderr,
            )
            quantization = None

    # Download dir: honor HF_HOME (set by the workflow to the cached path) so
    # weights land in the actions/cache directory and get reused across runs.
    download_dir = os.environ.get("HF_HOME", "/tmp/hf-cache")

    # Build vLLM CLI args (consumed by scripts/serve.sh)
    args: list[str] = [
        "--host", "0.0.0.0",
        "--port", "8000",
        "--served-model-name", served_name,
        "--dtype", dtype,
        "--max-model-len", str(max_model_len),
        "--download-dir", download_dir,
    ]
    if device not in ("metal", "cpu") and engine != "ollama":
        # GPU memory utilization is meaningless on the Metal/CPU backend and
        # ignored by the Ollama engine.
        args += ["--gpu-memory-utilization", str(gpu_mem_util)]
    if engine != "ollama" and quantization and quantization != "none":
        args += ["--quantization", quantization]
    args += model.get("extra_vllm_args", [])
    extra = os.environ.get("INPUT_EXTRA_ARGS", "").strip()
    if extra:
        args += shlex.split(extra)

    # Per-model env (merged over defaults)
    env = {**defaults.get("env", {}), **model.get("env", {})}

    if model.get("requires_hf_token") and not os.environ.get("HF_TOKEN"):
        print(
            f"::warning::model '{model_key}' is gated on Hugging Face — "
            "set the HF_TOKEN secret or the download will fail.",
            file=sys.stderr,
        )

    env_values = {
        "RUNNER_LABELS_JSON": json.dumps(runner_labels),
        "HF_REPO": hf_repo,
        "VLLM_VERSION": vllm_version,
        "VLLM_ARGS": " ".join(shlex.quote(a) for a in args),
        "MODEL_ENV_JSON": json.dumps(env),
        "SERVED_MODEL_NAME": served_name,
        "RESOLVED_QUANTIZATION": quant_key,
        "DEVICE": device or "cuda",
        "ENGINE": engine,
    }
    output_values = {
        "runner_labels": json.dumps(runner_labels),
        "hf_repo": hf_repo,
        "vllm_version": vllm_version,
        "served_model_name": served_name,
        "resolved_quantization": quant_key,
        "device": device or "cuda",
        "engine": engine,
    }

    github_env = os.environ.get("GITHUB_ENV")
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_env:
        write_env_file(github_env, env_values)
    if github_output:
        write_env_file(github_output, output_values)

    print(json.dumps({"model_key": model_key, **env_values}, indent=2))


if __name__ == "__main__":
    main()
