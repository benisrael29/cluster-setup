#!/bin/bash
# Kubernetes Master Node Setup Script for Xubuntu on Macbook Air
# This script configures the first Macbook Air as the Kubernetes control plane node

set -e

# Variables - modify as needed
POD_NETWORK_CIDR="10.244.0.0/16"
API_ADVERTISE_ADDRESS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
KUBERNETES_VERSION="1.27.0"
HOSTNAME=$(hostname)
NODE_NAME="master-node"

# Print script info
echo "==============================================="
echo "Kubernetes Master Node Setup"
echo "-----------------------------------------------"
echo "This script will configure this machine as the"
echo "Kubernetes control plane node"
echo "==============================================="

# Update package list and install prerequisites
echo "[1/8] Updating system and installing prerequisites..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg

# Disable swap (required for Kubernetes)
echo "[2/8] Disabling swap..."
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Configure kernel modules and sysctl
echo "[3/8] Configuring kernel modules and system settings..."
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
echo "[4/8] Installing containerd as container runtime..."
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
echo "[5/8] Installing Kubernetes components (kubeadm, kubelet, kubectl)..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet=${KUBERNETES_VERSION}-* kubeadm=${KUBERNETES_VERSION}-* kubectl=${KUBERNETES_VERSION}-*
sudo apt-mark hold kubelet kubeadm kubectl

# Initialize the Kubernetes control-plane node
echo "[6/8] Initializing Kubernetes control plane..."
sudo hostnamectl set-hostname $NODE_NAME
echo "127.0.0.1 $NODE_NAME" | sudo tee -a /etc/hosts

sudo kubeadm init --pod-network-cidr=$POD_NETWORK_CIDR \
  --apiserver-advertise-address=$API_ADVERTISE_ADDRESS \
  --kubernetes-version=$KUBERNETES_VERSION \
  --node-name=$NODE_NAME

# Set up kubeconfig for the user
echo "[7/8] Setting up kubectl configuration..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
echo "export KUBECONFIG=$HOME/.kube/config" | tee -a $HOME/.bashrc

# Install Calico network plugin
echo "[8/8] Installing Calico as the pod network plugin..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/tigera-operator.yaml
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: $POD_NETWORK_CIDR
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF

# Generate the join command for worker nodes
echo "[+] Generating worker node join command..."
JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)
echo "Use the following command on your worker node to join the cluster:"
echo "$JOIN_COMMAND"
echo
echo "-----------------------------------------------------------"
echo "✅ Kubernetes control plane setup complete!"
echo "📋 Please save the above join command to use on worker nodes"
echo "-----------------------------------------------------------"

# Verify the cluster status
kubectl get nodes 