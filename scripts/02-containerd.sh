#!/usr/bin/env bash
set -euo pipefail
CFG=/etc/containerd/config.toml

echo "### 1. backup current config (has disabled_plugins=[\"cri\"])"
sudo cp -n $CFG ${CFG}.orig.$(date +%Y%m%d) 2>/dev/null || true
ls -l /etc/containerd/

echo "### 2. generate default config (containerd 2.x -> config version 3, CRI enabled)"
containerd config default | sudo tee $CFG >/dev/null
grep -m1 '^version' $CFG

echo "### 3. SystemdCgroup=true (host is cgroup v2 + kubelet uses systemd driver)"
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' $CFG
grep -n 'SystemdCgroup' $CFG

echo "### 4. register the nvidia runtime and make it the default"
# Default (not just a RuntimeClass) so llm-d/vLLM manifests work unmodified -
# they do not set runtimeClassName. nvidia-container-runtime only injects
# devices when NVIDIA_VISIBLE_DEVICES is set, so system pods are unaffected.
sudo nvidia-ctk runtime configure --runtime=containerd --config=$CFG --set-as-default --cdi.enabled
grep -n -A3 'default_runtime_name\|runtimes.nvidia\]' $CFG | head -20

echo "### 5. restart + verify"
sudo systemctl restart containerd
sleep 3
sudo systemctl is-active containerd
sudo ctr version | head -4
echo "--- CRI plugin status ---"
sudo ctr plugins ls 2>/dev/null | grep -iE 'cri' || true
