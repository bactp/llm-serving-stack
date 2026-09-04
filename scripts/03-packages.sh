#!/usr/bin/env bash
set -euo pipefail
K8S_MINOR=v1.36
K8S_VER=1.36.4-1.1

echo "### 1. apt prereqs"
sudo apt-get update -qq
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg conntrack socat ipvsadm nfs-common

echo "### 2. pkgs.k8s.io repo ($K8S_MINOR)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -qq

echo "### 3. install kubelet/kubeadm/kubectl/cri-tools = $K8S_VER"
sudo apt-get install -y -qq kubelet="$K8S_VER" kubeadm="$K8S_VER" kubectl="$K8S_VER" cri-tools
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet >/dev/null 2>&1

echo "### 4. crictl endpoint"
cat <<'C' | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 20
C

echo "### 5. helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash >/dev/null 2>&1

echo "### VERSIONS"
kubeadm version -o short
kubectl version --client -o yaml | grep gitVersion | head -1
kubelet --version
crictl --version
helm version --short
