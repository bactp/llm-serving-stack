#!/usr/bin/env bash
# A LoadBalancer IP curled from the HOST before kube-proxy programs it leaves a
# stale "SYN_SENT [UNREPLIED]" conntrack entry that blocks DNAT until it expires.
# Run this after creating a LoadBalancer Service (e.g. the agentgateway Gateway),
# or just curl from inside a pod, which is unaffected.
set -euo pipefail
IP="${1:?usage: lb-flush.sh <loadbalancer-ip>}"
sudo conntrack -D -d "$IP" 2>/dev/null || true
echo "flushed conntrack entries for $IP"
