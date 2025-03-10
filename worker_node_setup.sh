#!/bin/bash
# Kubernetes Worker Node Setup Script for Xubuntu on Macbook Air
# This script configures the second Macbook Air as a Kubernetes worker node

set -e

# Variables - modify as needed
KUBERNETES_VERSION="1.27.0"
NODE_NAME="worker-node-1"

# Print script info
echo "==============================================="
echo "Kubernetes Worker Node Setup"
echo "-----------------------------------------------"
echo "This script will configure this machine as a"
echo "Kubernetes worker node"
echo "==============================================="

# Update package list and install prerequisites
echo "[1/6] Updating system and installing prerequisites..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg

# Disable swap (required for Kubernetes)
echo "[2/6] Disabling swap..."
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Configure kernel modules and sysctl
echo "[3/6] Configuring kernel modules and system settings..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Install containerd as container runtime
echo "[4/6] Installing containerd as container runtime..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y containerd.io

# Configure containerd
mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install Kubernetes components
echo "[5/6] Installing Kubernetes components (kubeadm, kubelet, kubectl)..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet=${KUBERNETES_VERSION}-* kubeadm=${KUBERNETES_VERSION}-* kubectl=${KUBERNETES_VERSION}-*
sudo apt-mark hold kubelet kubeadm kubectl

# Set hostname
echo "[6/6] Setting hostname..."
sudo hostnamectl set-hostname $NODE_NAME
echo "127.0.0.1 $NODE_NAME" | sudo tee -a /etc/hosts

echo "==============================================="
echo "Worker node preparation complete!"
echo "==============================================="
echo 
echo "To join this node to your Kubernetes cluster, run the 'kubeadm join' command"
echo "that was output when you initialized the control plane node."
echo 
echo "The command should look similar to:"
echo "sudo kubeadm join <MASTER_IP>:6443 --token <TOKEN> \\"
echo "    --discovery-token-ca-cert-hash sha256:<HASH>"
echo 
echo "Once you run this command, go back to your master node and verify"
echo "that the new node has joined with: kubectl get nodes"
echo "===============================================" 