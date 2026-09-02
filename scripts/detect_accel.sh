#!/usr/bin/env bash
# detect_accel.sh — detect the best available accelerator on this machine and
# emit routing decisions. NEVER selects plain CPU: if no accelerator is found
# it exits non-zero so the workflow fails fast instead of deploying on CPU.
#
# Detection order (best first):
#   1. NVIDIA CUDA  (nvidia-smi)            -> device=cuda
#   2. Apple Metal  (macOS + Apple Silicon) -> device=metal
#   3. (none)                               -> error, exit 1
#
# Outputs (to $GITHUB_OUTPUT if set, else stdout):
#   device          cuda | metal
#   runner_labels   JSON array for runs-on
#   vllm_device     value for vLLM (cuda | cpu-on-metal via mlx/gguf)
#   accel_name      human-readable accelerator name
#   vram_gb         total VRAM/unified-memory GB (best effort)
#   dtype           recommended dtype
#   extra_vllm_args recommended extra args for the device
set -euo pipefail

device=""
accel_name="unknown"
vram_gb=0
dtype="auto"
extra_args=""
runner_labels='["self-hosted"]'

# --- 1. NVIDIA CUDA ---------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  device="cuda"
  accel_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)"
  vram_gb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk '{printf "%d", $1/1024}')"
  dtype="auto"
  runner_labels='["self-hosted","gpu","cuda"]'
  # large VRAM tiers
  if [[ "${vram_gb:-0}" -ge 40 ]]; then
    runner_labels='["self-hosted","gpu","cuda","gpu-xl"]'
  elif [[ "${vram_gb:-0}" -ge 20 ]]; then
    runner_labels='["self-hosted","gpu","cuda","gpu-large"]'
  fi

# --- 2. Apple Silicon / Metal ----------------------------------------------
elif [[ "$(uname -s)" == "Darwin" ]]; then
  arch="$(uname -m)"
  if [[ "$arch" == "arm64" ]]; then
    device="metal"
    accel_name="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
    # unified memory — total RAM is the pool shared with the GPU
    mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    vram_gb="$(( mem_bytes / 1024 / 1024 / 1024 ))"
    dtype="float16"
    runner_labels='["self-hosted","macos","metal"]'
    # vLLM on Apple Silicon runs CPU backend; Metal is used via MLX/GGUF.
    # Signal serve.sh to use the Metal path instead of vanilla vLLM.
    extra_args="--device cpu"
  fi
fi

# --- 3. allow CPU fallback --------------------------------------------------
# Ollama can run GGUF models on CPU in CI; other engines will fail fast in serve.sh.
if [[ -z "$device" ]]; then
  device="cpu"
  accel_name="CPU"
  vram_gb=0
  dtype="float16"
  runner_labels='["self-hosted","cpu"]'
  extra_args=""
fi

echo "detected: device=$device accel='$accel_name' vram=${vram_gb}GB labels=$runner_labels"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "device=$device"
    echo "runner_labels=$runner_labels"
    echo "accel_name=$accel_name"
    echo "vram_gb=$vram_gb"
    echo "dtype=$dtype"
    echo "extra_vllm_args=$extra_args"
  } >> "$GITHUB_OUTPUT"
else
  printf 'device=%s\nrunner_labels=%s\naccel_name=%s\nvram_gb=%s\ndtype=%s\nextra_vllm_args=%s\n' \
    "$device" "$runner_labels" "$accel_name" "$vram_gb" "$dtype" "$extra_args"
fi
