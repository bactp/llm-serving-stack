#!/usr/bin/env bash
# Send a request through the agentgateway Gateway from inside the cluster.
# With no model server deployed this returns HTTP 503 "failed to find endpoint
# candidates" - which still proves gateway -> ext_proc -> EPP is wired.
set -euo pipefail
source /home/ubuntu/llm-stack/llm-d.env
IP=$(kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.addresses[0].value}')
MODEL="${1:-Qwen/Qwen3-8B}"
PROMPT="${2:-hello}"
echo "gateway=${IP} model=${MODEL}"
kubectl run "curl-probe-$RANDOM" -n "${NAMESPACE}" --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  -s -m 60 -w '\n--> HTTP %{http_code}\n' -X POST "http://${IP}/v1/completions" \
  -H 'Content-Type: application/json' \
  -H "X-Gateway-Base-Model-Name: ${GUIDE_NAME}" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"${PROMPT}\",\"max_tokens\":64}"
