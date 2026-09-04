#!/usr/bin/env bash
# Add user_id/tier/models metadata to key entries minted before virtual keys
# existed, without changing their keyHash - so keys already handed out keep
# working. Entries that already have user_id are left alone.
set -euo pipefail
CUR=$(kubectl -n llm-d-system get secret llm-api-keys -o json | jq -r '.data // {}')
PATCH=$(echo "$CUR" | jq -r --arg t "${DEFAULT_TIER:-standard}" '
  to_entries | map(
    .key as $k | (.value | @base64d | fromjson) as $v |
    select($v.metadata.user_id == null) |
    {key: $k, value: ($v | .metadata = ((.metadata // {}) + {user_id: $k, tier: $t}) | tojson)}
  ) | from_entries')
if [ "$PATCH" = "{}" ]; then echo "nothing to migrate"; exit 0; fi
echo "$PATCH" | jq -r 'keys | "migrating: " + join(", ")'
kubectl -n llm-d-system patch secret llm-api-keys --type merge -p "$(jq -nc --argjson s "$PATCH" '{stringData:$s}')"
