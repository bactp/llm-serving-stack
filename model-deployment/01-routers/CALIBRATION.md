# peakPrefillThroughput calibration

Measured 2026-09-03 with `llm-d/guides/recipes/router/calibration/calibrate.sh`,
aimed at a **single vLLM pod** (`VLLM_ENDPOINT=http://<pod-ip>:8000`) rather than
through the router — the filter uses this to estimate *per-endpoint* TTFT, so a
single endpoint is what should be measured.

| Model | Measured | Applied |
|---|---|---|
| `qwen3-8b` | 3507 / 3516 / 3592 tok/s | **3516** |
| `gpt-oss-20b` | 5985 / 6011 tok/s | **5985** |
| plugin default | 15928 (Qwen3-32B, H100 80GB, TP=2) | — |

The default overstates this hardware by ~4.5x for `qwen3-8b` and ~2.7x for
`gpt-oss-20b`. Left uncorrected the filter believes every endpoint drains its
queue far faster than it does, so its TTFT estimates collapse toward zero and
prefix-cache affinity stops yielding to load.

`gpt-oss-20b` prefills **1.7x faster than the dense 8B** despite being nominally
larger: it is an MoE with roughly 3.6B active parameters per token, so prefill
FLOPs track the active count, not the total.

## Finding the right CHUNK_SIZE

The README says `CHUNK_SIZE` must equal vLLM's `--max-num-batched-tokens`. That
flag is not set here and the engine's startup banner does not print the resolved
value, so it was found by sweeping instead — throughput peaks at the scheduler's
real chunk size and falls off either side:

| CHUNK_SIZE | qwen3-8b | gpt-oss-20b |
|---|---|---|
| 1024 | 3335 | 5722 |
| **2048** | **3592** | **6011** |
| 3072 | 3349 | — |
| 4096 | 3462 | 5622 |
| 8192 | 3180 | — |

Peak at 2048 on both, so vLLM's effective `max_num_batched_tokens` is 2048.
Below it, fixed per-request overhead is not amortised; above it, the prompt is
split across several scheduler steps and pays that overhead repeatedly.

## Re-running

```bash
cd ../../llm-d/guides/recipes/router/calibration
IP=$(kubectl get pods -n llm-d-system -l llm-d.ai/model=qwen3-8b \
      --field-selector status.phase=Running -o jsonpath='{.items[0].status.podIP}')
GUIDE_NAME=qwen3-8b NAMESPACE=llm-d-system MODEL_NAME=qwen3-8b \
  VLLM_ENDPOINT="http://$IP:8000" CHUNK_SIZE=2048 \
  NUM_WARMUP=5 NUM_MEASUREMENTS=20 bash ./calibrate.sh
```

Two things the script's defaults get wrong in this deployment:

* It auto-discovers `VLLM_ENDPOINT` from the `<guide>-epp` Service on the port
  named `http` (80 -> 8081). In **Gateway Mode** nothing listens on 8081 — that
  port is for the Envoy sidecar that only Standalone Mode deploys — so
  auto-discovery yields a dead endpoint and `VLLM_ENDPOINT` must be set.
* `MODEL_NAME` must be a name vLLM answers to. Both work here (`qwen3-8b` and
  `Qwen/Qwen3-8B`) because of `--served-model-name`.

Re-measure after any change to TP size, quantisation, `--max-model-len`,
`--kv-cache-dtype`, GPU model, or the vLLM version — all of them move this number.
