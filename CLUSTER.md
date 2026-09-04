# Single-node K8s cluster for llm-d + agentgateway

Host: AWS `g6.12xlarge` — 48 vCPU, 181 GiB RAM, 4x NVIDIA L4 24GB (sm_89, no NVLink)
Node: `ip-172-31-32-97` / `172.31.32.97` (public `3.35.241.155`)

## Installed (Phase 1)

| Component | Version | Notes |
|---|---|---|
| Kubernetes | v1.36.4 | kubeadm, single node, control-plane taint removed |
| containerd | v2.2.1 | CRI enabled, config v3, `SystemdCgroup=true`, **default runtime = nvidia**, CDI on |
| CNI | Flannel v0.28.9 | vxlan, `--iface=enp39s0`, pod CIDR `10.244.0.0/16` |
| GPU | GPU Operator v26.7.0 | `driver.enabled=false`, `toolkit.enabled=false` (DLAMI supplies both) |
| StorageClass | local-path v0.0.37 | **default**, backed by `/var/lib/local-path-provisioner` on the EBS root (NOT the instance store - see gotcha 1) |
| LoadBalancer | MetalLB v0.16.1 | L2 mode, pool `172.31.32.240-172.31.32.249` |
| Metrics | metrics-server v0.9.0 | `--kubelet-insecure-tls` |
| Helm | v3.21.4 | |

Service CIDR `10.96.0.0/12`, DNS `10.96.0.10`, kubeconfig `~/.kube/config`.

## Host changes made

- `/etc/modules-load.d/k8s.conf` — `overlay`, `br_netfilter`
- `/etc/sysctl.d/99-k8s.conf` — bridge-nf-call-iptables, ip_forward, inotify + file limits
- `/etc/containerd/config.toml` (+ `conf.d/99-nvidia.toml`) — original saved as `config.toml.orig.20260903`
- `/etc/systemd/system/k8s-forward-accept.service` — **fixes docker's `iptables -P FORWARD DROP`**, which otherwise breaks pod networking
- `/etc/tmpfiles.d/llm-stack.conf` — recreates the NVMe cache dirs after reboot (no weights)
- `/etc/crictl.yaml` — points crictl at containerd

## Gotchas

1. **`/opt/dlami/nvme` is ephemeral** — wiped by an EC2 stop/start (not by reboot). etcd and
   `/var/lib/kubelet` are on the EBS root, so the cluster itself survives. As of 2026-09-04
   **no model weights live here**: the `model-pvc` PV points at `/home/ubuntu/llm-stack/hf-backup`
   on the EBS root instead, because a stop/start silently emptied this path and left every
   decode pod in `ContainerCreating` on a `FailedMount`. The instance store now holds only
   the vLLM torch.compile cache (`/opt/dlami/nvme/vllm-cache/<model>`), which is a pure
   cache. local-path PVCs were moved off it the same day for the same reason: Prometheus
   and Alertmanager were given real volumes, and a PVC provisioned onto the instance store
   would have looked persistent while still being wiped by every stop/start. Note that `/etc/tmpfiles.d/llm-stack.conf` recreating a
   directory here is racy against LVM assembly of the ephemeral VG, which is a second reason
   not to put anything that must exist at kubelet start on this disk.
2. **Decode deployments must roll with `maxSurge: 0`.** Each replica pins a whole L4 and the
   two pools saturate all 4 GPUs, so the default 25% maxSurge rounds up to 1, the surge pod
   sits `Pending` on `Insufficient nvidia.com/gpu`, and the rollout deadlocks. Both
   `patch-vllm.yaml` files now set `maxSurge: 0 / maxUnavailable: 1`.
3. **Stale `ContainerStatusUnknown` pods hold their GPU reservations.** After an unclean
   restart, clear them with
   `kubectl delete pod -n llm-d-system --field-selector status.phase=Failed`, or replacements
   stay `Pending` on `Insufficient nvidia.com/gpu` even with `nvidia-smi` reporting 0 MiB.
4. **MetalLB IPs are node-local.** They are not assigned to the EC2 ENI, so they work from
   the node and from pods, but not from elsewhere in the VPC. For outside access use
   `kubectl port-forward` or point an AWS NLB/ALB at the Service's NodePort.
5. **Fresh LoadBalancer + curl from host** can hang on a stale conntrack entry —
   run `scripts/lb-flush.sh <ip>`, or curl from inside a pod.
6. **nvidia is containerd's default runtime**, so llm-d/vLLM manifests need no
   `runtimeClassName`. Containers without `NVIDIA_VISIBLE_DEVICES` are unaffected.
7. kubelet/kubeadm/kubectl are `apt-mark hold` at 1.36.4 — `apt-mark unhold` before upgrading.

## Files

    kubeadm-config.yaml           cluster config used by kubeadm init
    kubeadm-init.log              full init output (join token, cert hash)
    scripts/01-preflight.sh       host prep
    scripts/02-containerd.sh      CRI + nvidia runtime
    scripts/03-packages.sh        kubeadm/kubelet/kubectl/helm
    scripts/99-validate.sh        full cluster validation
    scripts/lb-flush.sh           conntrack workaround for LoadBalancer IPs
    scripts/download-models.sh    HF model download (NVMe + EBS backup)
    scripts/restore-models.sh     OBSOLETE - weights live on EBS now, see model-deployment/bin/post-restart.sh
    values/gpu-operator.values.yaml
    values/kube-prometheus-stack.values.yaml   monitoring; Prometheus 20Gi + Alertmanager 2Gi on EBS
    manifests/                    flannel, local-path, metallb pool

---

# Phase 2a — llm-d + agentgateway infrastructure (no model server yet)

Installed by `scripts/10-llm-d-infra.sh`; all versions live in `llm-d.env`
(which sources `llm-d/guides/env.sh` for the repo's own pins).

| Component | Version | Where |
|---|---|---|
| llm-d repo | `v0.9.0` (tag) | `/home/ubuntu/llm-stack/llm-d` |
| Gateway API | v1.5.1 (standard) | cluster-scoped CRDs |
| Gateway API Inference Extension | v1.5.0 (`v1-manifests.yaml`) | `inferencepools.inference.networking.k8s.io` |
| agentgateway | **v1.5.0** | ns `agentgateway-system` |
| llm-d router chart / EPP | v0.10.0 | ns `llm-d-system` |

Namespace is **`llm-d-system`**, deliberately not the guide-derived `llm-d-optimized-baseline`
that llm-d's README exports: the gateway and EPP are shared infrastructure, so the namespace is
named for the stack rather than for whichever well-lit path is deployed into it. `NAMESPACE` in
`llm-d.env` is the single source of truth — a namespace cannot be renamed in place, so changing
it means `helm uninstall` + `kubectl delete namespace` + re-running `scripts/10-llm-d-infra.sh`.
Delete the old namespace *before* recreating, so MetalLB hands the same VIP back.

Namespace `llm-d-system` holds:

    gateway/llm-d-inference-gateway     class=agentgateway, PROGRAMMED=True, address 172.31.32.240
    httproute/optimized-baseline        Accepted=True, ResolvedRefs=True -> InferencePool
    inferencepool/optimized-baseline    Accepted by agentgateway.dev/agentgateway
                                        selector llm-d.ai/guide=optimized-baseline, targetPort 8000
                                        endpointPickerRef -> optimized-baseline-epp:9002 (FailOpen)
    deploy/optimized-baseline-epp       1/1 Running (llm-d endpoint picker)
    deploy/llm-d-inference-gateway      1/1 Running (agentgateway proxy)
    secret/llm-d-hf-token               placeholder - all 5 downloaded models are ungated

Request path: client -> MetalLB VIP :80 -> agentgateway proxy -> ext_proc gRPC :9002 -> EPP
-> scheduling profile (`prefix-cache-affinity-filter` + `token-load-scorer`) -> a pod in the
InferencePool. `scripts/11-probe-gateway.sh` exercises it.

## Version notes

- **agentgateway v1.5.0, not the v1.1.0 in llm-d's doc.** That doc is stale; v1.5.0's chart
  carries `inference.networking.k8s.io` InferencePool RBAC, matching GAIE v1.5.0's GA API.
- **`provider.name=none`, not `agentgateway`.** The guide README lists `agentgateway` as an
  option but router chart v0.10.0 only implements `gke`, `istio` and `none`; agentgateway
  needs no provider-specific resources, and the GatewayClass is selected on the Gateway itself.
- **Gateway Mode, not Standalone Mode.** Standalone gives the EPP an Envoy sidecar and no
  Gateway API object, so it cannot use agentgateway. Gateway Mode uses
  `llm-d-router-gateway` and wires an HTTPRoute to the Gateway.
- **InferenceObjective is not installed.** It is llm-d's own `llm-d.ai/v1alpha2` CRD, only
  rendered when `router.inferenceObjectives` is set (it is empty here).

## Expected state until a model server exists

    $ scripts/11-probe-gateway.sh
    inference error: ServiceUnavailable - failed to find endpoint candidates for serving the request
    --> HTTP 503

The InferencePool selector matches zero pods. This 503 comes *from the EPP*, so it confirms
the whole path is wired — anything broken upstream would fail before reaching the EPP.

---

# Phase 2b — model serving

Deployed and verified 2026-09-03. Everything lives in `model-deployment/`; read
its `README.md` for the on/off workflow and client configuration — this section
only records what changed at the cluster level.

Added: cert-manager v1.21.1 (ns `cert-manager`, installed with
`config.enableGatewayAPI=true` so ACME HTTP-01 can be solved through a Gateway
API HTTPRoute instead of an Ingress).

Two llm-d router helm releases replaced the single `optimized-baseline` one:
`qwen3-8b` and `gpt-oss-20b`, each with its own EPP + InferencePool, selecting
pods by `llm-d.ai/model`.

## Two things the llm-d and agentgateway docs do not tell you

1. **A Gateway listener must name `AgentgatewayModel` in `allowedRoutes.kinds`.**
   llm-d's `recipes/gateway/agentgateway` sets only
   `allowedRoutes.namespaces.from: All`, and a listener's default supportedKinds
   is HTTPRoute + GRPCRoute. Without the extra kind every model attaches with
   `Accepted=False / NotAllowedByListeners` and every request returns
   `404 route not found` — with nothing in the model's own status to suggest the
   listener is the problem until you read `status.parents[].conditions`.
   That is why the Gateway now lives in `model-deployment/20-gateway/` rather
   than being applied straight from the llm-d recipe.

2. **`AgentgatewayModel.spec.custom.formats` is required** and its enum is
   `Completions | Responses | Embeddings | Messages | Rerank | Realtime |
   AnthropicTokenCount`. `Completions` covers `/v1/chat/completions` only.

## Internet exposure

`AgentgatewayParameters.spec.service.spec.externalIPs: [172.31.32.97]` makes
kube-proxy answer on the node's own IP on 80/443, which the Elastic IP NATs — so
the gateway is served on standard ports with no extra proxy. The MetalLB VIP
(172.31.32.240) still works from inside and is what `Gateway.status.addresses`
reports, but it is not reachable from outside the VPC. NodePorts are pinned to
30080/30443.

TCP 80 and 443 are open in security group `sg-069a7c118e74997a1`
(ap-northeast-2). Keep **80** open: HTTP-01 revalidates on every renewal.

Live endpoint: `https://3-35-241-155.sslip.io/v1`, Let's Encrypt certificate,
API-key auth, serving `qwen3-8b` and `gpt-oss-20b`.

Two ordering traps found while wiring this up, both recorded in
`model-deployment/README.md`:

* The Gateway-wide `apiKeyAuthentication` policy also covers cert-manager's ACME
  solver route, so Let's Encrypt got 401 and the order stalled. Fixed by a second
  policy in `Optional` mode attached via `targetSelectors` to the
  `acme.cert-manager.io/http01-solver` label.
* `AgentgatewayModel` routes bound to the Gateway as a whole answer on the
  HTTP listener too, and they out-prioritise a catch-all redirect HTTPRoute — so
  the redirect silently did nothing and cleartext requests kept being served.
  The models now pin `parentRefs[].sectionName: https`, leaving `:80` with only
  the redirect and the ACME solver.

The `IPP` (Inference Payload Processor) fallback from the plan was not needed:
`AgentgatewayModel` handles model-name routing natively, and agentgateway serves
`/v1/models` itself, so the planned `directResponse` workaround was dropped too.

## Admin console exposure

The agentgateway UI is served at `https://admin.3-35-241-155.sslip.io/ui` behind
HTTP Basic auth, added on the user's explicit request after they asked for
access without `kubectl port-forward`. `model-deployment/50-admin-ui/` holds it
and `model-deployment/README.md` documents the three traps involved
(`ADMIN_ADDR` loopback bind, policies merging rather than overriding, and
`$apr1$` hashes being rejected in favour of bcrypt).

It is an operations console — `/config_dump` and a PUT-able `/logging` — on a
public endpoint. Deleting `50-admin-ui/` withdraws it completely.

## Monitoring

kube-prometheus-stack + Grafana in `llm-d-monitoring`, installed via llm-d's
`guides/recipes/observability/install-prometheus-grafana.sh`. Prometheus selects
ServiceMonitors and PodMonitors in **all** namespaces (empty selectors), and the
Grafana dashboard sidecar watches `NAMESPACE=ALL` for ConfigMaps labelled
`grafana_dashboard=1` — so both llm-d's dashboards and the one shipped by the
agentgateway chart are picked up automatically.

Grafana is published at `https://grafana.3-35-241-155.sslip.io` (third SAN on the
Let's Encrypt certificate) with the gateway's Bearer policy relaxed to `Optional`
on that route, leaving Grafana's own login as the control. The chart default
`admin/admin` was rotated; the password is in
`model-deployment/70-grafana/GRAFANA-LOGIN.txt`.

Two failure modes recorded in `model-deployment/README.md` because both produce
empty dashboards with no error: the agentgateway proxy PodMonitor defaulting to
the release namespace, and the GPU Operator caching API discovery from before the
Prometheus CRDs existed (needs a pod restart, not a helm upgrade).
