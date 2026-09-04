#!/usr/bin/env bash
echo "########## 1. NODE ##########"
kubectl get node -o wide
echo "-- capacity/allocatable --"
kubectl get node -o json | jq '.items[0].status | {cap_gpu:.capacity["nvidia.com/gpu"], alloc_gpu:.allocatable["nvidia.com/gpu"], cpu:.allocatable.cpu, mem:.allocatable.memory, pods:.allocatable.pods}'

echo; echo "########## 2. ALL PODS ##########"
kubectl get pods -A -o wide | grep -vE 'Running|Completed' || echo "(all pods Running/Completed)"
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c

echo; echo "########## 3. GPU IN A POD (all 4) ##########"
kubectl delete pod gpu-check --ignore-not-found >/dev/null 2>&1
kubectl run gpu-check --rm -i --restart=Never --image=nvidia/cuda:12.6.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"gpu-check","image":"nvidia/cuda:12.6.1-base-ubuntu22.04","command":["nvidia-smi","--query-gpu=index,name,memory.total,compute_cap","--format=csv"],"resources":{"limits":{"nvidia.com/gpu":"4"}}}]}}' 2>&1 | grep -v '^pod '

echo; echo "########## 4. DNS ##########"
kubectl delete pod dns-check --ignore-not-found >/dev/null 2>&1
kubectl run dns-check --rm -i --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -E 'Name|Address|can.t' | head -5

echo; echo "########## 5. STORAGE (PVC on NVMe) ##########"
kubectl delete pvc pvc-check --ignore-not-found >/dev/null 2>&1
cat <<'P' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-check}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 5Gi}}
P
kubectl delete pod pvc-writer --ignore-not-found >/dev/null 2>&1
kubectl run pvc-writer --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"pvc-writer","image":"busybox:1.36","command":["sh","-c","echo ok > /data/t && cat /data/t && df -h /data | tail -1"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"pvc-check"}}]}}' >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvc-writer --timeout=90s >/dev/null 2>&1
kubectl logs pvc-writer 2>&1
kubectl get pvc pvc-check --no-headers
kubectl delete pod pvc-writer --ignore-not-found >/dev/null 2>&1; kubectl delete pvc pvc-check --ignore-not-found >/dev/null 2>&1

echo; echo "########## 6. LOADBALANCER (MetalLB) ##########"
kubectl delete svc lb-check --ignore-not-found >/dev/null 2>&1
kubectl delete deploy lb-check --ignore-not-found >/dev/null 2>&1
kubectl create deploy lb-check --image=nginx:1.27-alpine >/dev/null
kubectl expose deploy lb-check --port=80 --type=LoadBalancer >/dev/null
for i in $(seq 1 20); do
  IP=$(kubectl get svc lb-check -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$IP" ] && break; sleep 3
done
echo "LoadBalancer IP: ${IP:-NONE}"
kubectl rollout status deploy/lb-check --timeout=90s >/dev/null 2>&1
[ -n "$IP" ] && curl -s -m 10 -o /dev/null -w "curl http://$IP/ -> HTTP %{http_code}\n" "http://$IP/"
kubectl delete svc lb-check deploy lb-check --ignore-not-found >/dev/null 2>&1

echo; echo "########## 7. METRICS ##########"
kubectl top node 2>&1 | head -3

echo; echo "########## 8. VERSIONS ##########"
printf "kubernetes  %s\n" "$(kubectl version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)"
printf "containerd  %s\n" "$(sudo ctr version | awk '/Version/{print $2; exit}')"
printf "helm        %s\n" "$(helm version --short)"
printf "cni         flannel %s\n" "$(kubectl -n kube-flannel get ds kube-flannel-ds -o jsonpath='{.spec.template.spec.containers[0].image}' | cut -d: -f2)"
helm list -A
