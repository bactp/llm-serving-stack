#!/usr/bin/env bash
set -euo pipefail
echo "### 1. kernel modules"
cat <<'M' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
M
sudo modprobe overlay
sudo modprobe br_netfilter

echo "### 2. sysctl"
cat <<'S' | sudo tee /etc/sysctl.d/99-k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# many pods + vLLM workers open a lot of watches/files
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
fs.file-max                         = 2097152
vm.max_map_count                    = 262144
S
sudo sysctl --system >/dev/null
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward fs.inotify.max_user_instances

echo "### 3. swap off (already 0, make it explicit + persistent)"
sudo swapoff -a || true
sudo sed -i.bak '/\sswap\s/s/^\(.*\)$/#\1/' /etc/fstab 2>/dev/null || true
free -h | grep -i swap

echo "### 4. fix docker's 'iptables -P FORWARD DROP' which breaks pod networking"
cat <<'U' | sudo tee /etc/systemd/system/k8s-forward-accept.service >/dev/null
[Unit]
Description=Force iptables FORWARD policy to ACCEPT for Kubernetes pod networking
# docker sets FORWARD DROP on start; run after it so we win
After=docker.service containerd.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -P FORWARD ACCEPT
ExecStart=/usr/sbin/ip6tables -P FORWARD ACCEPT

[Install]
WantedBy=multi-user.target
U
sudo systemctl daemon-reload
sudo systemctl enable --now k8s-forward-accept.service
sudo iptables -S FORWARD | head -1

echo "### 5. persist NVMe dirs across reboot (DLAMI remounts /opt/dlami/nvme empty)"
cat <<'T' | sudo tee /etc/tmpfiles.d/llm-stack.conf >/dev/null
d /opt/dlami/nvme/hf                    0755 ubuntu ubuntu -
d /opt/dlami/nvme/local-path            0755 root   root   -
T
sudo systemd-tmpfiles --create /etc/tmpfiles.d/llm-stack.conf
ls -ld /opt/dlami/nvme/hf /opt/dlami/nvme/local-path

echo "### PREFLIGHT OK"
