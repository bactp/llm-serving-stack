#!/usr/bin/env bash
# Mint a virtual key for a client/agent.
#
#   bin/gen-api-key.sh <client-name> [--tier free|standard|premium] [model ...]
#   bin/gen-api-key.sh coding-agent --tier premium qwen3-8b gpt-oss-20b
#
# The entry carries metadata that other policies read as CEL:
#   user_id  -> becomes a Prometheus label on every metric for this key
#               (see ../60-virtual-keys/metrics-policy.yaml)
#   tier     -> selects a token rate-limit bucket
#               (see ../60-virtual-keys/ratelimit-policy.yaml)
#   models   -> informational for now; enforce it with an authorization rule
#
# Only the sha256 hash is stored in the cluster. The plaintext is printed once
# and appended to 30-api-keys/KEYS.txt (mode 600, gitignored); it cannot be
# recovered afterwards - mint a new key instead.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?usage: gen-api-key.sh <client-name> [--tier free|standard|premium] [model ...]}"; shift
TIER=standard
if [ "${1:-}" = "--tier" ]; then TIER="${2:?--tier needs a value}"; shift 2; fi
case "$TIER" in free|standard|premium) ;; *) echo "tier must be free, standard or premium"; exit 1;; esac
MODELS=("$@"); [ ${#MODELS[@]} -eq 0 ] && MODELS=(qwen3-8b gpt-oss-20b)

KEY="sk-llmd-$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
HASH="sha256:$(printf '%s' "$KEY" | sha256sum | cut -d' ' -f1)"
MODELS_JSON=$(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -sc .)

ENTRY=$(jq -nc --arg h "$HASH" --arg u "$NAME" --arg t "$TIER" --argjson m "$MODELS_JSON" \
  '{keyHash:$h, metadata:{user_id:$u, tier:$t, models:$m}}')

kubectl -n llm-d-system patch secret llm-api-keys --type merge \
  -p "$(jq -nc --arg k "$NAME" --arg v "$ENTRY" '{stringData:{($k):$v}}')"

umask 077
{ echo "# $(date -Is)  client=$NAME  tier=$TIER  models=${MODELS[*]}"; echo "$KEY"; } >> 30-api-keys/KEYS.txt
chmod 600 30-api-keys/KEYS.txt

echo
echo "client : $NAME    tier: $TIER    models: ${MODELS[*]}"
echo "API KEY: $KEY"
echo
echo "  export OPENAI_BASE_URL=https://3-35-241-155.sslip.io/v1"
echo "  export OPENAI_API_KEY=$KEY"
echo
echo "(also appended to 30-api-keys/KEYS.txt, mode 600 - this is the only copy)"
