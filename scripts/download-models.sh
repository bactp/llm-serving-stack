#!/usr/bin/env bash
# Download LLM models for the llm-d stack on 4x NVIDIA L4 (24GB each = 96GB total).
#
#   tmux new -s dl 'bash ~/llm-stack/scripts/download-models.sh 2>&1 | tee ~/llm-stack/dl.log; exec bash'
#
# Strategy: download to fast ephemeral NVMe, then rsync a persistent copy to the EBS
# root disk so an EC2 stop/start does not force a re-download from HuggingFace.
set -uo pipefail

NVME_HOME="${NVME_HOME:-/opt/dlami/nvme/hf}"       # primary, 3.8 GB/s, EPHEMERAL
EBS_BACKUP="${EBS_BACKUP:-/home/ubuntu/llm-stack/hf-backup}"  # persistent copy on EBS
DO_BACKUP="${DO_BACKUP:-1}"                         # set 0 to skip the rsync step
PARALLEL="${PARALLEL:-2}"                           # 2 repos saturates the ~120 MiB/s HF link

export HF_HOME="$NVME_HOME"
export HF_HUB_DOWNLOAD_TIMEOUT=60
# export HF_TOKEN=hf_xxx        # not needed: all repos below are ungated

# repo                                   download size   placement on 4x L4
MODELS=(
  "Qwen/Qwen3-0.6B"          #   1.4 GiB   TP=1 - smoke test, validates the stack fast
  "Qwen/Qwen3-8B"            #  15.3 GiB   bf16 TP=1 - 4 replicas, or 2 prefill + 2 decode
  "Qwen/Qwen3-32B-FP8"       #  32.0 GiB   FP8  TP=2 - native FP8 on Ada, ~14GB KV left
  "openai/gpt-oss-20b"       #  12.8 GiB   MXFP4 TP=1 (Marlin kernels)
  "openai/gpt-oss-120b"      #  60.0 GiB   MXFP4 TP=4 - uses all 4 GPUs, ~35GB KV left
)                            # ~121.5 GiB total => ~18 min at 120 MiB/s

# Skip the MLX/metal and bf16 "original" copies - unusable by vLLM, and they double
# or triple the repo size (gpt-oss-120b is 182 GiB on HF, only 60 GiB of it is needed).
EXCLUDE=()
for p in "original/*" "metal/*" "*.pth" "*.gguf" "*.onnx" "consolidated*"; do
  EXCLUDE+=(--exclude "$p")
done

# ---- setup ------------------------------------------------------------------
sudo mkdir -p "$NVME_HOME" && sudo chown -R "$(id -u):$(id -g)" "$NVME_HOME"
mkdir -p "$NVME_HOME/logs" "$EBS_BACKUP"
echo "==> HF_HOME   = $NVME_HOME"; df -h "$NVME_HOME" | tail -1
echo "==> EBS backup= $EBS_BACKUP (DO_BACKUP=$DO_BACKUP)"; df -h "$EBS_BACKUP" | tail -1

export PATH="$HOME/.local/bin:$PATH"
command -v hf >/dev/null 2>&1 || { echo "==> installing huggingface_hub[hf_xet]"; pip3 install -q -U "huggingface_hub[hf_xet]" || exit 1; }
command -v hf >/dev/null 2>&1 || { echo "!! hf still not on PATH after install"; exit 1; }
hf version

# ---- download ---------------------------------------------------------------
t0=$(date +%s)
for m in "${MODELS[@]}"; do
  log="$NVME_HOME/logs/$(echo "$m" | tr '/' '_').log"
  echo "==> START $m   (log: $log)"
  ( hf download "$m" "${EXCLUDE[@]}" >"$log" 2>&1 \
      && echo "== OK   $m" || echo "== FAIL $m  -> tail -30 $log" ) &
  while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do sleep 2; done
done
wait
echo "==> download finished in $(( $(date +%s) - t0 ))s"
echo; du -sh "$NVME_HOME"/hub/models--* 2>/dev/null; du -sh "$NVME_HOME"

# ---- persistent backup on EBS ----------------------------------------------
if [ "$DO_BACKUP" = "1" ]; then
  echo; echo "==> rsync -> $EBS_BACKUP  (~15 min for 121 GiB at 140 MB/s, safe to interrupt)"
  t1=$(date +%s)
  rsync -a --info=progress2 --exclude 'logs/' "$NVME_HOME/" "$EBS_BACKUP/"
  echo "==> backup finished in $(( $(date +%s) - t1 ))s"; du -sh "$EBS_BACKUP"
fi

echo; echo "==> ALL DONE. Total $(( $(date +%s) - t0 ))s"
hf cache ls 2>/dev/null | tail -12
