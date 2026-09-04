#!/usr/bin/env bash
# Phase 2a: llm-d + agentgateway infrastructure, no model server.
# Idempotent - safe to re-run.
set -euo pipefail
cd /home/ubuntu/llm-stack
source llm-d.env
source "${REPO_ROOT}/guides/env.sh"

echo "### 1. Gateway API ${GATEWAY_API_VERSION} + GAIE ${GAIE_VERSION} CRDs"
bash "${REPO_ROOT}/guides/recipes/gateway/install-gateway-crds.sh"

echo "### 2. agentgateway ${AGENTGATEWAY_VERSION}"
helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  -n agentgateway-system --create-namespace --version "${AGENTGATEWAY_VERSION}" --wait
helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  -n agentgateway-system --create-namespace --version "${AGENTGATEWAY_VERSION}" \
  --set inferenceExtension.enabled=true --wait

echo "### 3. namespace + HF token secret"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN:-hf_placeholder_ungated_models_only}" \
  -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "### 4. Gateway (${GATEWAY_CLASS})"
kubectl apply -k "${REPO_ROOT}/guides/recipes/gateway/agentgateway" -n "${NAMESPACE}"
kubectl wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" -n "${NAMESPACE}" --timeout=180s

echo "### 5. llm-d router ${ROUTER_CHART_VERSION} (Gateway Mode: EPP + InferencePool + HTTPRoute)"
helm upgrade --install "${GUIDE_NAME}" "${ROUTER_GATEWAY_CHART}" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/${GUIDE_NAME}/router/${GUIDE_NAME}.values.yaml" \
  --set provider.name="${PROVIDER_NAME}" \
  --set httpRoute.create=true \
  --set httpRoute.inferenceGatewayName="${GATEWAY_NAME}" \
  -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}" --wait --timeout 8m

echo "### done"
kubectl get gateway,httproute,inferencepool,pods -n "${NAMESPACE}"
