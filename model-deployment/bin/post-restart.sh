#!/usr/bin/env bash
# Run this after every EC2 stop/start. Idempotent - safe to run when nothing changed.
#
#   model-deployment/bin/post-restart.sh
#
# Model weights need no action any more (they are on the EBS root, see
# 00-storage/model-weights-pv.yaml). What DOES still need attention:
#   1. the public IP changes on a stop/start, which invalidates every sslip.io
#      hostname and the TLS cert SANs
#   2. pods left in ContainerStatusUnknown keep their GPU reservations, so their
#      replacements sit Pending on Insufficient nvidia.com/gpu
set -euo pipefail
cd "$(dirname "$0")/.."
STACK=/home/ubuntu/llm-stack
NS=llm-d-system

echo "==> 1. public IP"
NEW_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 || true)
[ -n "$NEW_IP" ] || { echo "    could not read public IP from IMDS"; exit 1; }
OLD_DASH=$(grep -oE '[0-9]+-[0-9]+-[0-9]+-[0-9]+\.sslip\.io' 40-tls/certificate.yaml | head -1 | cut -d. -f1)
OLD_IP=${OLD_DASH//-/.}
NEW_DASH=${NEW_IP//./-}
echo "    manifests say : $OLD_IP"
echo "    instance has  : $NEW_IP"

if [ "$OLD_IP" != "$NEW_IP" ]; then
  echo "==> 2. rewriting hostnames ($OLD_DASH -> $NEW_DASH)"
  grep -rl "$OLD_DASH\|$OLD_IP" "$STACK" 2>/dev/null | grep -v kubeadm-init.log | while read -r f; do
    sed -i "s/$OLD_DASH/$NEW_DASH/g; s/${OLD_IP//./\\.}/$NEW_IP/g" "$f"; echo "    $f"
  done
  echo "==> 3. re-applying cert + routes"
  kubectl apply -f 40-tls/certificate.yaml -f 41-https-redirect.yaml \
                -f 70-grafana/httproute.yaml -f 50-admin-ui/httproute.yaml
  echo "    waiting for cert-manager to reissue (HTTP-01 needs port 80 open)..."
  kubectl wait --for=condition=Ready certificate/llm-d-gateway-tls -n $NS --timeout=300s
else
  echo "==> 2. IP unchanged - no hostname rewrite needed"
  echo "==> 3. cert untouched"
fi

echo "==> 4. clearing stale pods that still hold GPU reservations"
STALE=$(kubectl get pods -n $NS --field-selector status.phase=Failed --no-headers 2>/dev/null | wc -l)
if [ "$STALE" -gt 0 ]; then
  kubectl delete pod -n $NS --field-selector status.phase=Failed
else
  echo "    none"
fi

echo "==> 5. waiting for the model pools"
kubectl rollout status deploy/qwen3-8b-decode   -n $NS --timeout=900s
kubectl rollout status deploy/gpt-oss-20b-decode -n $NS --timeout=900s

echo
kubectl get pods -n $NS
echo
echo "Endpoint: https://${NEW_DASH}.sslip.io/v1"
echo "Grafana : https://grafana.${NEW_DASH}.sslip.io"
echo
echo "NOTE: the first pod start after a boot recompiles - the NVMe compile cache goes"
echo "      with the instance store. Prometheus history now survives (EBS-backed PVC)."
