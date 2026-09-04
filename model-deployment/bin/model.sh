#!/usr/bin/env bash
# Turn model pools on and off.
#
#   bin/model.sh on   qwen3-8b|gpt-oss-20b|all
#   bin/model.sh off  qwen3-8b|gpt-oss-20b|all
#   bin/model.sh status
#
# "off" deletes the vLLM Deployment and frees its GPUs; the pool's EPP,
# InferencePool and AgentgatewayModel stay up, so requests for that model
# return 503 from the EPP until it is switched back on.
#
# There are only 4 L4s. qwen3-8b and gpt-oss-20b each take 2 (1 per replica),
# so both on at once is exactly full. Check bin/model.sh status before adding
# anything else.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=llm-d-system
declare -A DIR=( [qwen3-8b]=10-modelserver-qwen3-8b [gpt-oss-20b]=11-modelserver-gpt-oss-20b )

status () {
  echo "== GPUs =="
  ALLOC=$(kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')
  USED=$(kubectl get pods -A -o json | jq '[.items[] | select(.status.phase=="Running") | .spec.containers[].resources.requests["nvidia.com/gpu"] // "0" | tonumber] | add')
  echo "  ${USED:-0} / ${ALLOC} in use"
  echo; echo "== pods =="
  kubectl get pods -n $NS -o wide --no-headers | awk '{printf "%-46s %-7s %s\n",$1,$2,$3}'
  echo; echo "== pool endpoints =="
  for p in "${!DIR[@]}"; do
    n=$(kubectl get pods -n $NS -l "llm-d.ai/model=$p" --field-selector status.phase=Running --no-headers 2>/dev/null | grep -c '1/1' || true)
    printf "%-14s %s ready endpoint(s)\n" "$p" "${n:-0}"
  done
  echo; echo "== models advertised by the gateway =="
  kubectl get agentgatewaymodel -n $NS --no-headers 2>/dev/null | awk '{printf "  %-20s -> match %s\n",$1,$2}'
}

case "${1:-}" in
  status) status ;;
  on|off)
    ACT=$1; TARGET="${2:?usage: model.sh $1 <qwen3-8b|gpt-oss-20b|all>}"
    LIST=( "$TARGET" ); [ "$TARGET" = all ] && LIST=( qwen3-8b gpt-oss-20b )
    for m in "${LIST[@]}"; do
      d="${DIR[$m]:-}"; [ -z "$d" ] && { echo "unknown model: $m"; exit 1; }
      if [ "$ACT" = on ]; then
        echo "==> on: $m"; kubectl apply -k "$d/"
        kubectl rollout status "deploy/${m}-decode" -n $NS --timeout=20m
      else
        echo "==> off: $m"; kubectl delete -k "$d/" --ignore-not-found
      fi
    done
    echo; status ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 1 ;;
esac
