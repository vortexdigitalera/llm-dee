#!/usr/bin/env python3
"""Validate models.json against models.schema.json.

Uses jsonschema if installed, otherwise falls back to a built-in minimal
validator covering the constraints the engine relies on. Exits non-zero on
any violation. Also usable as a pre-commit / CI check.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "models.json"
SCHEMA = REPO_ROOT / "models.schema.json"

REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
# Ollama tags can reference HF repos via hf.co/<org>/<repo>:<tag>
OLLAMA_TAG_RE = re.compile(r"^hf\.co/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$")
KNOWN_QUANTS = {"awq", "gptq", "fp8", "nvfp4", "compressed-tensors", "squeezellm", "marlin", "none"}
KNOWN_DTYPES = {"auto", "float16", "bfloat16", "float32"}


def err(errors: list[str], msg: str) -> None:
    errors.append(msg)


def minimal_validate(catalog: dict) -> list[str]:
    errors: list[str] = []
    defaults = catalog.get("defaults", {})
    models = catalog.get("models")
    if not isinstance(models, dict) or not models:
        err(errors, "catalog must contain a non-empty 'models' object")
        return errors

    for key, model in models.items():
        where = f"models.{key}"
        hf_repo = model.get("hf_repo", "")
        if not REPO_RE.match(hf_repo):
            err(errors, f"{where}.hf_repo '{hf_repo}' is not a valid 'org/repo'")

        quants = model.get("quantizations")
        if not isinstance(quants, dict) or not quants:
            err(errors, f"{where}.quantizations must be a non-empty object")
            continue

        default_q = model.get("default_quantization")
        if default_q not in quants:
            err(errors, f"{where}.default_quantization '{default_q}' not in quantizations {sorted(quants)}")

        for qname, q in quants.items():
            qwhere = f"{where}.quantizations.{qname}"
            repo = q.get("repo", "")
            if not (REPO_RE.match(repo) or OLLAMA_TAG_RE.match(repo)):
                err(errors, f"{qwhere}.repo '{repo}' is not a valid 'org/repo' or Ollama hf.co tag")
            if "quantization" in q and q["quantization"] not in KNOWN_QUANTS:
                err(errors, f"{qwhere}.quantization '{q['quantization']}' not in {sorted(KNOWN_QUANTS)}")
            if "dtype" in q and q["dtype"] not in KNOWN_DTYPES:
                err(errors, f"{qwhere}.dtype '{q['dtype']}' not in {sorted(KNOWN_DTYPES)}")

        for field in ("max_model_len",):
            if field in model and (not isinstance(model[field], int) or model[field] < 256):
                err(errors, f"{where}.{field} must be an integer >= 256")
        for field in ("gpu_memory_utilization",):
            if field in model and not (0 < float(model[field]) <= 1):
                err(errors, f"{where}.{field} must be in (0, 1]")

        labels = model.get("runner_labels", defaults.get("runner_labels"))
        if not labels or not all(isinstance(l, str) for l in labels):
            err(errors, f"{where}.runner_labels must be a non-empty list of strings")

    return errors


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))

    try:
        import jsonschema  # type: ignore

        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        jsonschema.validate(catalog, schema)
        print("models.json: valid (jsonschema)")
        return 0
    except ImportError:
        pass
    except Exception as exc:  # jsonschema.ValidationError
        print(f"models.json: INVALID — {exc}", file=sys.stderr)
        return 1

    errors = minimal_validate(catalog)
    if errors:
        for e in errors:
            print(f"models.json: INVALID — {e}", file=sys.stderr)
        return 1
    print("models.json: valid (builtin validator)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
