# llm-dee — LLM inference core engine on GitHub Actions + Cloudflare quick tunnel

Run any Hugging Face model through **vLLM** on a GitHub Actions runner and expose a
public **OpenAI-compatible endpoint** through a **Cloudflare quick tunnel** —
no Argo, no named tunnel, no Cloudflare account, no token.

Dispatch the workflow, pick a **model**, a **runner**, and a **quantization**
from the local [models.json](models.json) catalog, and get a
`https://<random>.trycloudflare.com` URL serving `/v1/chat/completions`.

```mermaid
flowchart LR
    A[workflow_dispatch<br/>model / runner / quant] --> B[resolve job<br/>models.json]
    B --> C[serve job on GPU runner]
    C --> D[vLLM OpenAI server<br/>:8000]
    C --> E[cloudflared quick tunnel]
    D --> E
    E --> F[https://random.trycloudflare.com]
    G[keepalive cron] -->|re-dispatch if dead| A
```

## Quick start

1. **Fork / push this repo** to your GitHub account.
2. **Attach a self-hosted GPU runner** (Settings → Actions → Runners) with the
   labels `self-hosted,gpu` (add `gpu-large` for 14B+ models).
   GitHub-hosted runners have no GPU — a self-hosted runner is required.
3. *(Recommended)* set repo secrets:
   - `LLM_API_KEY` — bearer token required by the endpoint (without it the
     endpoint is **public and unauthenticated**).
   - `HF_TOKEN` — needed for gated repos (Llama, Gemma).
4. **Actions → "Run LLM (vLLM + Cloudflare quick tunnel)" → Run workflow**:
   choose model, quantization, TTL. The endpoint URL appears in the job
   summary within a few minutes.

```bash
curl https://<random>.trycloudflare.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{"model": "qwen3.8-27b-uncensored", "messages": [{"role":"user","content":"hi"}]}'
```

### Quick run

For a fast smoke test, tick **`quick_run`** in the dispatch form — it skips the
in-runner warmup and external probe and forces a **15-minute TTL** so you get
an endpoint fast without burning runner time.

Or use the helper script:

```bash
# Local quick run (on a GPU machine with this repo checked out)
./scripts/quick_run.sh qwen3.8-27b-uncensored fp8

# Dispatch the GitHub Actions workflow with quick_run=true
./scripts/quick_run.sh qwen3.8-27b-uncensored fp8 --dispatch
```

## How it routes (accelerator auto-detect, no CPU)

The workflow runs on **GitHub-hosted `macos-latest`** (Apple Silicon). It
detects the accelerator inline and picks the serving backend:

| Detected | Backend | Notes |
|---|---|---|
| Apple Silicon (macOS arm64) | **MLX (`mlx-lm`)** | Native Apple backend, OpenAI-compatible server on `:8000` |
| NVIDIA CUDA | **vLLM** | CUDA quants (fp8/nvfp4/awq/gptq) |
| **none** | — | **fails fast, no CPU deploy** |

[scripts/detect_accel.sh](scripts/detect_accel.sh) does the detection;
[scripts/serve.sh](scripts/serve.sh) branches on it (Metal → MLX, CUDA → vLLM);
[scripts/resolve_model.py](scripts/resolve_model.py) adapts the flags.

> **Why MLX on macOS, not vLLM:** vLLM publishes **no macOS/arm64 wheel** and
> cannot be source-built on the `macos-26` runner (its Python is 3.14 while
> vLLM needs `<3.14`, and the build pins a `torch` that doesn't exist for 3.14).
> vLLM simply does not support Apple Silicon. The native Apple backend is
> **MLX**, so on `macos-latest` the engine serves via `mlx_lm.server`, which
> exposes the same OpenAI-compatible `/v1/chat/completions` endpoint.
>
> Use an **MLX-format model** on this path — the catalog ships
> `qwen2.5-1.5b-mlx-4bit` (mlx-community) which fits a hosted runner's unified
> memory. The big OrcaRouter CUDA models (27B–360B) will not fit and are not
> MLX-format; they need a CUDA GPU runner.

## Repository layout

| Path | Purpose |
|---|---|
| [models.json](models.json) | Model catalog: HF repos, quant variants, runner labels, vLLM tuning |
| [models.schema.json](models.schema.json) | JSON schema for the catalog |
| [.github/workflows/run-llm.yml](.github/workflows/run-llm.yml) | Core dispatch workflow (resolve → serve → tunnel → probe → TTL) |
| [.github/workflows/keepalive.yml](.github/workflows/keepalive.yml) | Cron that re-dispatches if the endpoint died |
| [.github/workflows/cleanup.yml](.github/workflows/cleanup.yml) | Cancels stale queued runs, prunes old caches |
| [.github/actions/resolve-model/action.yml](.github/actions/resolve-model/action.yml) | Composite action wrapping the resolver |
| [scripts/resolve_model.py](scripts/resolve_model.py) | Catalog → vLLM flags resolver |
| [scripts/serve.sh](scripts/serve.sh) | Installs pinned vLLM, starts server, waits for health, warms up |
| [scripts/start_tunnel.sh](scripts/start_tunnel.sh) | Pinned cloudflared quick tunnel + URL extraction + summary |
| [scripts/probe.sh](scripts/probe.sh) | External end-to-end probe through the tunnel |
| [scripts/stop.sh](scripts/stop.sh) | Best-effort cleanup |
| [scripts/warmup_runner.sh](scripts/warmup_runner.sh) | One-time runner prep + persistent HF cache |
| [scripts/validate_catalog.py](scripts/validate_catalog.py) | Catalog validation (CI / pre-commit) |
| [cloudflared/config.yml](cloudflared/config.yml) | Quick-tunnel config + notes for named tunnels |
| [examples/](examples/) | Python + curl clients |

## The model catalog

Everything is driven by [models.json](models.json). Each entry defines the HF
repo, the available quantization variants (each can point at a *different* HF
repo, e.g. `-AWQ`), runner labels, VRAM floor, and vLLM tuning:

```jsonc
"qwen3.8-27b-uncensored": {
  "hf_repo": "orcarouter/Qwen3.8-27B-Uncensored",
  "runner_labels": ["self-hosted", "gpu", "gpu-large"],
  "requires_hf_token": true,
  "quantizations": {
    "bf16": { "repo": "orcarouter/Qwen3.8-27B-Uncensored", "dtype": "bfloat16" },
    "fp8":  { "repo": "orcarouter/Qwen3.8-27B-Uncensored-FP8", "quantization": "fp8" },
    "nvfp4": { "repo": "orcarouter/Qwen3.8-27B-Uncensored-NVFP4", "quantization": "nvfp4" }
  },
  "default_quantization": "fp8",
  "max_model_len": 32768,
  "min_vram_gb": 32
}
```

Add your own model by copying a block — the dispatch dropdown is the
`options:` list in [run-llm.yml](.github/workflows/run-llm.yml), so add the key
there too. Validate with `python3 scripts/validate_catalog.py`.

### Current catalog — [OrcaRouter](https://huggingface.co/orcarouter) models

The catalog currently ships **only OrcaRouter uncensored models** (all GATED —
set the `HF_TOKEN` secret and accept the licenses on Hugging Face first):

| Key | HF repo | Quants | Weights | Runner |
|---|---|---|---|---|
| `qwen3.8-27b-uncensored` | `orcarouter/Qwen3.8-27B-Uncensored` | bf16 / fp8 / nvfp4 / int8 | 25–56 GB | `gpu-large` |
| `qwen3.8-flash-next-uncensored` | `orcarouter/Qwen3.8-Flash-Next-Uncensored` | bf16 / fp8 / nvfp4 | 183–360 GB | `gpu-xl` (multi-GPU) |
| `glm-5.3-flash-uncensored` | `orcarouter/GLM-5.3-Flash-Uncensored-FP8` | fp8 / nvfp4 | 190–328 GB | `gpu-xl` (multi-GPU) |
| `gemma-4-26b-a4b-it-uncensored` | `orcarouter/Gemma-4-26B-A4B-it-Uncensored-FP8` | fp8 | 27 GB | `gpu-large` |

These are next-generation multimodal architectures (`Qwen3_5`, `Qwen4Exp`,
`Glm5Next`, `Gemma4` ForConditionalGeneration) and need a **recent vLLM**
(catalog pins `vllm_version: 0.11.0`). The big MoE models default to
`--tensor-parallel-size 4` — attach a multi-GPU runner labeled `gpu-xl`.

## Robustness playbook (the "more ideas" section)

### 1. Keeping the runner / endpoint alive
- **TTL + keepalive chain**: GitHub caps job duration (6h hosted / ~5 days
  self-hosted). `run-llm.yml` runs for `ttl_minutes`; the
  [keepalive workflow](.github/workflows/keepalive.yml) checks every 10 min
  and re-dispatches automatically when nothing is active. Enable with repo
  variables `LLMDEE_KEEPALIVE_ENABLED=true`, `LLMDEE_KEEPALIVE_MODEL`,
  `LLMDEE_KEEPALIVE_QUANT`, `LLMDEE_KEEPALIVE_TTL`.
- **Concurrency group** (`llm-dee-<model>`) prevents two servers fighting over
  one GPU.
- **Crash detection**: the keep-alive loop watches both PIDs and fails fast
  with logs if vLLM or cloudflared dies.
- **Runner as a service**: install the runner with `svc.sh install` so it
  survives reboots; pair with keepalive for self-healing.

### 2. Auto-scale
- **Horizontal**: register N runners with the same `gpu` label; GitHub
  load-balances queued jobs across idle runners. Dispatch one run per model —
  the concurrency group keys per model, so different models run in parallel on
  different GPUs.
- **Queue-depth scaling (advanced)**: a small external controller can poll
  `GET /repos/{repo}/actions/runs?status=queued` and boot cloud GPU VMs that
  register themselves as ephemeral runners
  (`POST /repos/{repo}/actions/runners/registration-token`), then remove them
  when idle. This gives you EC2/Lambda/RunPod burst capacity.
- **vLLM-level**: pass `--max-num-seqs`, `--enable-prefix-caching`,
  `--enable-chunked-prefill` via `extra_args` to raise per-GPU throughput
  instead of adding GPUs.

### 3. Caching
- **Persistent HF cache on the runner**: `HF_HOME=/opt/llm-dee/hf-cache`
  survives between runs → warm starts in seconds. Prep once with
  `scripts/warmup_runner.sh <model_key> <quant>`.
- **GitHub Actions cache** (`actions/cache@v4`) backs up the HF cache keyed by
  repo+quant — helps ephemeral runners (10 GB limit, use for small models).
- **`HF_HUB_ENABLE_HF_TRANSFER=1`** for multi-gigabit weight downloads.
- **Prefix caching**: `--enable-prefix-caching` in `extra_args` for repeated
  system prompts.

### 4. Rest / reliability extras
- **Health probes**: internal `/health` wait + external probe through the
  tunnel before the endpoint is announced.
- **Log artifacts**: `vllm.log` + `cloudflared.log` uploaded on every run
  (`if: always()`).
- **Cleanup cron**: cancels stale queued runs and prunes caches older than 7d.
- **Catalog validation** runs before every dispatch and can be a pre-commit
  hook.
- **Pinned versions**: vLLM per model, cloudflared pinned — no surprise
  breakages from upstream releases.

### 5. Security hardening
- Always set `LLM_API_KEY` — quick tunnels are public URLs.
- For a **stable hostname + Zero Trust auth**, graduate to a *named* tunnel
  with Cloudflare Access (see [cloudflared/config.yml](cloudflared/config.yml)).
- Never commit weights or tokens; `.gitignore` already covers caches.

### 6. Even more ideas
- **Matrix dispatch**: fan out one dispatch across several models for A/B
  benchmarking (add a `strategy.matrix` variant workflow).
- **Nightly smoke test**: schedule `run-llm.yml` with the 0.5B model + probe
  to catch runner drift.
- **Metrics**: cloudflared exposes Prometheus metrics on `127.0.0.1:20000`;
  vLLM exposes `/metrics` — scrape both from the runner.
- **GGUF/CPU fallback**: add a `quantization: gguf` variant using
  `llama.cpp`'s server for CPU-only runners.
- **Discord/Slack webhook** step to post the fresh endpoint URL wherever your
  team hangs out.

## Colab T4 auto-runner (via colabapi)

Don't have a GPU server? The repo can **provision a free Google Colab T4 as a
self-hosted runner**, deploy an LLM onto it, and **auto-heal** it — using
[colabapi](https://github.com/vortexdigitalera/colabapi), a ban-safe CLI over
Google's official Colab CLI (never handles your Google password).

```mermaid
flowchart LR
    A[workflow_dispatch] --> B[provision job<br/>on colab-controller]
    B -->|colabapi run --runtime t4| C[Colab T4 VM]
    B -->|register ephemeral runner| C
    C --> D[serve job<br/>vLLM + tunnel]
    E[heal job] -->|if down: stop + recreate| B
    F[cleanup job] -->|release runtime| C
```

**Workflow:** [.github/workflows/colab-runner.yml](.github/workflows/colab-runner.yml)
**Engine:** [scripts/colab_runner.py](scripts/colab_runner.py)

### One-time controller setup
You need a small always-on **controller** runner (CPU is fine — a VPS, your
laptop, a Raspberry Pi) that drives the Colab VM:

```bash
pipx install colabapi        # pulls Google's official colab CLI
colabapi login               # browser OAuth, no password stored
# register this machine as a runner labeled `colab-controller`
./config.sh --url https://github.com/<you>/llm-dee --token <tok> \
  --labels self-hosted,colab-controller --unattended
```

Set a repo secret `GH_PAT` (a PAT with `repo` + `workflow` scope) so the
workflow can mint ephemeral runner tokens.

### Run it
Actions → **"Colab T4 runner — provision, deploy & heal"** → Run workflow:
- `provision` brings up the T4 (`colabapi run --runtime t4`), registers it as
  an ephemeral runner, waits for it to come online.
- `serve` deploys the model + tunnel on the T4 and probes it.
- `heal` (if enabled and serve failed) tears down and recreates the runner.
- `cleanup` releases the Colab runtime when done.

### Manual control
```bash
python3 scripts/colab_runner.py up       # ensure T4 runner is up + online
python3 scripts/colab_runner.py status   # health: session alive? runner online?
python3 scripts/colab_runner.py heal     # if down/expired -> recreate
python3 scripts/colab_runner.py down     # remove runner + stop session
```

> **Size limit:** a Colab T4 has **16 GB VRAM**. Only the T4-sized models
> (`qwen2.5-0.5b`, `qwen2.5-1.5b`, `smollm2-1.7b`) fit. The big OrcaRouter MoE
> models (glm-5.3, qwen3.8-flash) need a real multi-GPU runner — use
> `run-llm.yml` for those. Colab free tier also caps sessions at ~12h.

## Notes & limits

- Quick-tunnel URLs are **ephemeral** — a new one every run. That's the price
  of "no Argo / no account". Use the keepalive chain + read the URL from the
  latest run's summary, or upgrade to a named tunnel for stability.
- GitHub ToS: don't use Actions as free production hosting. Self-hosted
  runners on your own hardware are the intended target here.
- The `resolve` job runs on `ubuntu-latest` (no GPU needed) so runner labels
  can be computed dynamically.

## License

MIT — see [LICENSE](LICENSE).
