#!/usr/bin/env bash
# One-shot migration: model weights off instance-store NVMe onto the EBS root, and
# the torch.compile cache off emptyDir onto NVMe. See 00-storage/model-weights-pv.yaml
# for why. Safe to re-run; it is idempotent apart from the recompile on first start.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=llm-d-system

echo "==> 0. preflight"
test -d /home/ubuntu/llm-stack/hf-backup/hub/models--Qwen--Qwen3-8B
test -d /home/ubuntu/llm-stack/hf-backup/hub/models--openai--gpt-oss-20b
echo "    weights present on EBS"

echo "==> 1. scale decode deployments to 0 (releases the PVC)"
kubectl scale deploy -n $NS qwen3-8b-decode gpt-oss-20b-decode --replicas=0
kubectl wait --for=delete pod -n $NS -l llm-d.ai/role=decode --timeout=180s 2>/dev/null || true
while [ "$(kubectl get pods -n $NS --no-headers 2>/dev/null | grep -c decode)" != "0" ]; do
  echo "    waiting for decode pods to terminate..."; sleep 5
done

echo "==> 2. drop the old PVC and the instance-store PV"
kubectl delete pvc -n $NS model-pvc --ignore-not-found --timeout=120s
kubectl delete pv model-weights-nvme --ignore-not-found --timeout=120s

echo "==> 3. create the EBS-backed PV + PVC"
kubectl apply -k 00-storage
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/model-pvc -n $NS --timeout=60s

echo "==> 4. re-apply modelservers (hostPath compile cache, replicas back to 2)"
kubectl apply -k 10-modelserver-qwen3-8b
kubectl apply -k 11-modelserver-gpt-oss-20b

echo "==> 5. wait for rollout"
kubectl rollout status deploy/qwen3-8b-decode -n $NS --timeout=900s
kubectl rollout status deploy/gpt-oss-20b-decode -n $NS --timeout=900s

echo
kubectl get pv,pvc -n $NS
kubectl get pods -n $NS
echo
echo "DONE. Compile cache now at /opt/dlami/nvme/vllm-cache/<model>."
