#!/usr/bin/env bash
# Smoke-test a model end to end through the gateway, with API key auth.
#   bin/test.sh [model] [prompt]
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL="${1:-qwen3-8b}"; PROMPT="${2:-Reply with exactly: OK}"
KEY=$(grep -v '^#' 30-api-keys/KEYS.txt 2>/dev/null | tail -1) || true
[ -z "${KEY:-}" ] && { echo "no key in 30-api-keys/KEYS.txt - run bin/gen-api-key.sh"; exit 1; }
# Called from the node, so use the node IP (the MetalLB VIP works too, but a
# stale conntrack entry can make it hang - see ../../scripts/lb-flush.sh).
BASE="${BASE:-http://172.31.32.97}"
EXTRA='{}'
[ "$MODEL" = qwen3-8b ] && EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}'
BODY=$(jq -nc --arg m "$MODEL" --arg p "$PROMPT" --argjson e "$EXTRA" \
  '{model:$m,messages:[{role:"user",content:$p}],max_tokens:200,temperature:0} * $e')
curl -sS -m 300 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d "$BODY" \
  | jq '{model, finish:.choices[0].finish_reason, content:.choices[0].message.content, usage}'
