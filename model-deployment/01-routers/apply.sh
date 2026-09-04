#!/usr/bin/env bash
# Install/upgrade the llm-d router (EPP + InferencePool) for each pool.
# These are helm releases, not kubectl-apply resources, and they are the
# always-on layer: leave them running and switch models by applying/deleting
# the modelserver overlays instead.
#
# monitoring.values.yaml adds the EPP ServiceMonitor. It needs the Prometheus
# Operator CRDs, which the llm-d observability recipe installs - running this
# before that stack exists fails with a Helm validation error.
set -euo pipefail
cd "$(dirname "$0")"
source /home/ubuntu/llm-stack/llm-d.env
source "${REPO_ROOT}/guides/env.sh"
for POOL in qwen3-8b gpt-oss-20b; do
  echo "==> router: ${POOL}"
  helm upgrade --install "${POOL}" "${ROUTER_GATEWAY_CHART}" \
    -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
    -f "${REPO_ROOT}/guides/recipes/router/features/monitoring.values.yaml" \
    -f "./${POOL}.values.yaml" \
    --set provider.name=none \
    -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}" \
    --wait --timeout 8m
done
kubectl get inferencepool,deploy -n "${NAMESPACE}"
