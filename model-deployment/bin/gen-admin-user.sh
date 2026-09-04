#!/usr/bin/env bash
# Create or replace a Basic-auth user for the agentgateway admin UI.
#
#   bin/gen-admin-user.sh <username> [password]
#
# With no password one is generated. Only the apr1 hash is stored in the
# cluster, in an .htaccess-format Secret; the plaintext is printed once and
# appended to 50-admin-ui/ADMIN-USERS.txt (mode 600, gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
USER="${1:?usage: gen-admin-user.sh <username> [password]}"
PASS="${2:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)}"
# bcrypt, not openssl's -apr1: agentgateway rejects $apr1$ hashes with
# "basic authentication failure: invalid credentials" despite the CRD docs
# listing MD5. $2b$ works.
HASH=$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_BLOWFISH)))" "$PASS")

# Rebuild the .htaccess body: keep other users, replace this one.
EXISTING=$(kubectl -n llm-d-system get secret agentgateway-admin-auth \
  -o jsonpath='{.data.\.htaccess}' 2>/dev/null | base64 -d 2>/dev/null || true)
BODY=$(printf '%s\n' "$EXISTING" | grep -v "^${USER}:" | grep -v '^$' || true)
BODY=$(printf '%s\n%s:%s\n' "$BODY" "$USER" "$HASH" | grep -v '^$')

kubectl -n llm-d-system create secret generic agentgateway-admin-auth \
  --from-literal=".htaccess=$BODY" --dry-run=client -o yaml | kubectl apply -f -

umask 077
{ echo "# $(date -Is)  admin UI user"; echo "${USER} / ${PASS}"; } >> 50-admin-ui/ADMIN-USERS.txt
chmod 600 50-admin-ui/ADMIN-USERS.txt

echo
echo "  https://admin.3-35-241-155.sslip.io/ui"
echo "  user     : $USER"
echo "  password : $PASS"
echo
echo "(also appended to 50-admin-ui/ADMIN-USERS.txt, mode 600)"
