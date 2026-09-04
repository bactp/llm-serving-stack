# Model deployment — llm-d + agentgateway on 4× NVIDIA L4

OpenAI-compatible endpoint: a client needs only `base_url`, `api_key` and a
`model` name. Two pools, two replicas each, all four GPUs in use.

| Model name (what clients send) | Alias | Pool | GPUs | KV cache | max_model_len |
|---|---|---|---|---|---|
| `qwen3-8b` | `Qwen/Qwen3-8B` | `qwen3-8b` | 2 × 1 | 48,144 tok (fp8 KV) | 16384 |
| `gpt-oss-20b` | `openai/gpt-oss-20b` | `gpt-oss-20b` | 2 × 1 | 172,580 tok | 32768 |

Two replicas per pool is deliberate: llm-d's EPP scorers
(`prefix-cache-affinity-filter`, `token-load-scorer`) only have a decision to
make when a pool has more than one endpoint.

## Turn models on and off

```bash
bin/model.sh status
bin/model.sh off gpt-oss-20b      # frees 2 GPUs, pool/EPP/route stay up
bin/model.sh on  gpt-oss-20b
bin/model.sh off all
```

Or straight kubectl — `bin/model.sh` is a thin wrapper over exactly this:

```bash
kubectl apply  -k 10-modelserver-qwen3-8b/      # on
kubectl delete -k 10-modelserver-qwen3-8b/      # off
```

**Only 4 GPUs exist.** Both pools on = exactly full. Anything else needs one
switched off first — check `bin/model.sh status` before adding a third pool.

## Layout

    00-storage/            PV+PVC exposing /home/ubuntu/llm-stack/hf-backup (123 GiB of weights) to pods
    01-routers/            helm values + apply.sh for the two llm-d routers (EPP + InferencePool)
                           CALIBRATION.md records the measured peakPrefillThroughput
    10-modelserver-*/      the ON/OFF unit: vLLM Deployment, 2 replicas   <- kubectl apply/delete -k
    11-modelserver-*/
    20-gateway/            Gateway (HTTP :80, HTTPS :443) + AgentgatewayParameters (Service pinning)
    21-model-routing/      AgentgatewayModel: maps the request body's "model" field to a pool
    30-api-keys/           Secret of hashed keys + AgentgatewayPolicy enforcing them
    40-tls/                cert-manager ClusterIssuers + Certificate (Let's Encrypt, 2 SANs)
    50-admin-ui/           agentgateway admin console on its own hostname, Basic auth
    60-virtual-keys/       per-key Prometheus labels + per-tier token budgets
    70-grafana/            Grafana on its own hostname
    41-https-redirect.yaml apply AFTER the cert is Ready
    bin/post-restart.sh    run after every EC2 stop/start (IP + cert + stale GPU pods)
    bin/model.sh           on / off / status
    bin/gen-api-key.sh     mint a key for a client
    bin/gen-admin-user.sh  mint a Basic-auth user for the admin console
    bin/migrate-keys.sh    backfill user_id/tier onto keys minted before virtual keys
    bin/test.sh            end-to-end smoke test

Order for a from-scratch rebuild: `00` → `01-routers/apply.sh` → `20` → `21` →
`30` → `10`/`11` → `40`.

## API keys

```bash
bin/gen-api-key.sh my-agent qwen3-8b gpt-oss-20b
```

Prints the key once and appends it to `30-api-keys/KEYS.txt` (mode 600, gitignored).
Only the sha256 hash goes into the cluster, so a lost key cannot be recovered —
mint a new one and delete the old entry from the Secret.

Auth is `Authorization: Bearer <key>` on every route of the Gateway
(`mode: Strict` — missing or unknown key is 401).

## Client / agent configuration

```bash
export OPENAI_BASE_URL=https://3-35-241-155.sslip.io/v1
export OPENAI_API_KEY=sk-llmd-...
```

> **Always configure `https://`.** Plain HTTP only redirects (301) — the models
> are bound to the `https` listener alone. And a redirect is not a safety net:
> `curl -L` **drops the `Authorization` header** when the scheme changes, so an
> http:// base_url ends in 401 *and* has already put the key on the wire in
> cleartext. (`curl --location-trusted` keeps the header, but do not rely on it.)
> The valid host is `3-35-241-155.sslip.io` — the certificate is issued for that
> name only, so `https://172.31.32.97/` terminates TLS but fails verification.

```python
from openai import OpenAI
client = OpenAI(base_url="https://3-35-241-155.sslip.io/v1", api_key="sk-llmd-...")
client.chat.completions.create(model="qwen3-8b", messages=[{"role":"user","content":"hi"}])
```

Switching models is one string. `GET /v1/models` lists all four names and is
served by the gateway itself.

### Endpoint support

| Endpoint | Works | Note |
|---|---|---|
| `POST /v1/chat/completions` | yes | streaming (`"stream": true`) included |
| `GET /v1/models` | yes | served by agentgateway from the AgentgatewayModel set |
| `POST /v1/completions` | **no — 404** | agentgateway's `Completions` format maps chat only. Clients stuck on legacy text completions need a direct HTTPRoute to the InferencePool |
| `POST /v1/embeddings` | no | `unsupported conversion ... to provider custom`; neither model is an embedding model anyway |

### TLS

Publicly trusted certificate from Let's Encrypt for `3-35-241-155.sslip.io`
(sslip.io maps any dashed IP in a hostname back to that IP, so no domain is
needed), renewed automatically by cert-manager over HTTP-01.

Two things had to be arranged for that to keep working, both easy to break:

* `30-api-keys/acme-exemption.yaml` puts the ACME solver route into
  `apiKeyAuthentication: Optional`, selected by cert-manager's
  `acme.cert-manager.io/http01-solver` label. Without it the Gateway-wide
  key policy answers Let's Encrypt with 401 and the order stalls on
  *"wrong status code '401', expected '200'"*.
* Port **80 must stay open** in the security group. HTTP-01 revalidates on
  every renewal, not just first issue.

Renewal was verified end to end by issuing a throwaway certificate from the
`letsencrypt-staging` ClusterIssuer with the redirect and the current listener
layout live. Repeat that check after any change to the Gateway or the key
policy:

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: renewal-check, namespace: llm-d-system}
spec:
  secretName: renewal-check-tls
  issuerRef: {name: letsencrypt-staging, kind: ClusterIssuer}
  dnsNames: ["3-35-241-155.sslip.io"]
EOF
kubectl wait --for=condition=Ready certificate/renewal-check -n llm-d-system --timeout=5m
kubectl delete certificate renewal-check -n llm-d-system
kubectl delete secret renewal-check-tls -n llm-d-system
```

### Per-model quirks

* **`qwen3-8b`** has Qwen3 thinking mode on by default and will spend the token
  budget on `<think>...`. Disable per request:
  `"chat_template_kwargs": {"enable_thinking": false}`.
* **`gpt-oss-20b`** uses the harmony format: the answer is in
  `message.content`, the scratchpad in `message.reasoning`. Give it room —
  under ~64 `max_tokens` it can spend everything on reasoning and return
  `content: null`.

## Notes

* `HF_HUB_OFFLINE=1` and `HF_HOME=/model-cache` — pods never reach
  huggingface.co. The `llm-d-hf-token` secret is a placeholder; all five
  downloaded models are ungated.
* `/opt/dlami/nvme` is wiped by an EC2 stop/start. Restore the weights with
  `../scripts/restore-models.sh` before turning models back on, or the pods
  crashloop on missing files.
* vLLM reports it could give `qwen3-8b` ~4.26 GiB of KV instead of 3.31 GiB at
  `--gpu-memory-utilization=0.95`. Left at 0.90 for headroom.
* `prefix-cache-affinity-filter`'s `peakPrefillThroughput` is calibrated for this
  hardware — 3516 tok/s for `qwen3-8b`, 5985 for `gpt-oss-20b`, against a plugin
  default of 15928 meant for H100. See `01-routers/CALIBRATION.md`, and re-measure
  after any change to TP size, quantisation, context length, GPU or vLLM version.

## Admin console

`https://admin.3-35-241-155.sslip.io/ui` — the agentgateway UI, plus
`/config_dump` (the full translated config) and a PUT-able `/logging`.

```bash
bin/gen-admin-user.sh admin           # prints user/password once
```

Three things had to line up, and each failed in a way that looked like something
else:

* **`ADMIN_ADDR=0.0.0.0:15000`** in `../20-gateway/agentgateway-params.yaml`.
  The admin listener binds `127.0.0.1:15000` by default — the container's own
  loopback — so a Service pointing at it exists but never answers, and
  `kubectl port-forward` is the only way in. Note this also makes the console
  reachable from any pod in the cluster, not just through the gateway.
* **Policies from different attachment points merge, they do not override.**
  Attaching `basicAuthentication` to the admin route was not enough: the
  Gateway-wide `apiKeyAuthentication` still ran and answered
  `no API Key found`. `50-admin-ui/policy.yaml` restates the key policy in
  `Optional` mode on this route to relax it — same shape as the ACME exemption.
* **Use bcrypt, not `$apr1$`.** The CRD documents "MD5, bcrypt, crypt and
  SHA-1", but an `openssl passwd -apr1` hash is rejected with
  `basic authentication failure: invalid credentials` even though it verifies
  locally. `bin/gen-admin-user.sh` generates `$2b$` via `crypt.METHOD_BLOWFISH`.

Isolation is enforced by hostname: the admin host does not serve models (401
even with a valid API key) and the API host does not serve the console (404).
Plain HTTP never serves either — `http://admin.../ui` returns 401 rather than
redirecting, because browsers carry no API key, so **always use `https://`**;
credentials sent to the http:// URL are on the wire before that 401 comes back.

> This is an operations console on a public endpoint, protected only by Basic
> auth over TLS. agentgateway's own docs recommend OIDC for anything beyond
> localhost. Narrowing the security group on 443 to known source IPs is the
> cheapest additional control. To withdraw it entirely:
> `kubectl delete -k 50-admin-ui/` and drop the `admin.` SAN from
> `40-tls/certificate.yaml`.

## Observability

`https://grafana.3-35-241-155.sslip.io` — login in `70-grafana/GRAFANA-LOGIN.txt`
(the chart default `admin/admin` was rotated). Prometheus and Grafana come from
llm-d's own recipe, `llm-d/guides/recipes/observability/install-prometheus-grafana.sh`,
in the `llm-d-monitoring` namespace, scraping all namespaces.

Eight scrape targets, all up:

| Source | What it gives |
|---|---|
| agentgateway proxy `:15020` | `agentgateway_gen_ai_*` — tokens in/out, TTFT, ITL, request duration, all labelled per key |
| agentgateway controller `:9092` | xDS, config sync |
| 2 × EPP `:9090` | llm-d routing decisions, scheduler latency |
| 4 × vLLM `:8000` | `vllm:kv_cache_usage_perc`, `num_requests_waiting`, `prefix_cache_hits_total` |
| dcgm-exporter `:9400` | per-GPU utilisation, VRAM, temperature, power |

Dashboards: **Agentgateway**, **Inference Gateway** (EPP), **llm-d vLLM Overview**,
**llm-d Performance Dashboard**, **llm-d Diagnostic Drill-Down**,
**llm-d Failure & Saturation Indicators**, plus the standard Kubernetes set.
(`P/D Coordinator Metrics` and `llm-d SGLang Overview` ship with the recipe but
stay empty — this deployment runs neither.)

### Two traps that produce silently empty panels

* **The proxy PodMonitor defaults to the release namespace only.** The proxy pod
  runs in `llm-d-system`, the chart installs in `agentgateway-system`, so
  `agentgateway_gen_ai_*` — the token and latency metrics, the whole point — was
  never scraped. Fixed with `--set monitoring.proxy.namespaceSelector.any=true`.
* **The GPU Operator caches API discovery at startup.** It was installed before
  the Prometheus Operator CRDs existed, so it silently never created the
  dcgm-exporter ServiceMonitor even though `ClusterPolicy` said
  `serviceMonitor.enabled: true`. A `helm upgrade` does not fix it; the operator
  needs `kubectl -n gpu-operator rollout restart deploy/gpu-operator`.

**TTFT and ITL only exist for streaming requests.** Non-streaming traffic
produces no `time_to_first_token` / `time_per_output_token` series at all — the
families are absent, not zero. Measured on this box: TTFT ~74 ms, ITL ~60 ms for
`qwen3-8b`, which is roughly the L4's memory-bandwidth ceiling for a 16 GiB bf16
model, not a tuning problem.

## Virtual keys

Each key carries `user_id`, `tier` and `models` metadata:

```bash
bin/gen-api-key.sh my-agent --tier premium qwen3-8b gpt-oss-20b
bin/migrate-keys.sh          # backfill older keys, keeps their keyHash
```

`60-virtual-keys/metrics-policy.yaml` turns `user_id` and `tier` into labels on
every agentgateway metric, so usage and cost break down per key:

```promql
sum by (user_id) (increase(agentgateway_gen_ai_client_token_usage_sum[24h]))
```

`60-virtual-keys/ratelimit-policy.yaml` sets hourly token ceilings per tier —
free 200k, standard 1M, premium 5M. **Two limits worth knowing before relying on
them:** the bucket is per *tier*, not per key, so everyone on `standard` shares
one pool; and token counts are only known once a request finishes, so the limit
bites the *next* request with a 429 rather than cutting off the current one.
True per-key daily budgets need `rateLimit.global` pointing at an Envoy
ratelimit service keyed on `user_id` — the metrics half already works without it.
