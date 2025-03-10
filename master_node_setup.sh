#!/bin/bash
# Kubernetes Master Node Setup Script for Xubuntu on Macbook Air
# This script configures the first Macbook Air as the Kubernetes control plane node

# Ensure script fails on any error
set -e

# Script name for logging
SCRIPT_NAME="master_node_setup.sh"

# Variables - modify as needed
POD_NETWORK_CIDR="10.244.0.0/16"
API_ADVERTISE_ADDRESS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
KUBERNETES_VERSION="1.27.0"
HOSTNAME=$(hostname)
NODE_NAME="master-node"
MIN_RAM_MB=2048
MIN_CPU_CORES=2
MIN_DISK_GB=20
LOG_FILE="/var/log/k8s_master_setup.log"
PROGRESS_FILE="/tmp/k8s_master_setup_progress"

# Create a function for logging
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a $LOG_FILE
}

# Create a function for error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Error occurred at line $line_number, exit code $exit_code"
        log "ERROR" "Check the log file at $LOG_FILE for details"
        log "ERROR" "Last successful step was: $(cat $PROGRESS_FILE 2>/dev/null || echo 'None')"
        log "ERROR" "To resume from the last successful step, run: $0 --resume"
        exit $exit_code
    fi
}

# Create a function to check system requirements
check_system_requirements() {
    log "INFO" "Checking system requirements..."
    
    # Check RAM
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))
    if [ $total_ram_mb -lt $MIN_RAM_MB ]; then
        log "WARNING" "System has only ${total_ram_mb}MB RAM. Recommended minimum is ${MIN_RAM_MB}MB."
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "ERROR" "Aborted due to insufficient RAM"
            exit 1
        fi
    fi
    
    # Check CPU cores
    local cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    if [ $cpu_cores -lt $MIN_CPU_CORES ]; then
        log "WARNING" "System has only $cpu_cores CPU cores. Recommended minimum is $MIN_CPU_CORES."
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "ERROR" "Aborted due to insufficient CPU cores"
            exit 1
        fi
    fi
    
    # Check disk space
    local root_disk_kb=$(df -k / | awk 'NR==2 {print $4}')
    local root_disk_gb=$((root_disk_kb / 1024 / 1024))
    if [ $root_disk_gb -lt $MIN_DISK_GB ]; then
        log "WARNING" "System has only ${root_disk_gb}GB free disk space. Recommended minimum is ${MIN_DISK_GB}GB."
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "ERROR" "Aborted due to insufficient disk space"
            exit 1
        fi
    fi
    
    # Check network connectivity
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        log "WARNING" "Network connectivity check failed. Internet access is required."
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "ERROR" "Aborted due to network connectivity issues"
            exit 1
        fi
    fi
    
    # Check if API_ADVERTISE_ADDRESS was detected correctly
    if [ -z "$API_ADVERTISE_ADDRESS" ]; then
        log "WARNING" "Could not automatically detect network interface IP address"
        read -p "Please enter the IP address to use for the Kubernetes API server: " API_ADVERTISE_ADDRESS
        if [ -z "$API_ADVERTISE_ADDRESS" ]; then
            log "ERROR" "No IP address provided. Aborting."
            exit 1
        fi
    fi
    
    log "INFO" "System requirements check completed successfully"
    return 0
}

# Create a function to check for existing installations
check_existing_installation() {
    log "INFO" "Checking for existing Kubernetes installation..."
    
    # Check if kubeadm is already installed
    if command -v kubeadm &>/dev/null; then
        local installed_version=$(kubeadm version -o short 2>/dev/null | cut -d'v' -f2)
        if [ ! -z "$installed_version" ]; then
            log "WARNING" "Kubernetes version $installed_version is already installed"
            read -p "Do you want to proceed and potentially overwrite the existing installation? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "INFO" "Installation aborted by user"
                exit 0
            fi
        fi
    fi
    
    # Check if kubernetes is already running
    if systemctl is-active --quiet kubelet; then
        log "WARNING" "Kubernetes services are already running"
        read -p "Do you want to proceed and potentially disrupt the existing cluster? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Installation aborted by user"
            exit 0
        fi
    fi
    
    log "INFO" "Existing installation check completed"
    return 0
}

# Create a function to initialize the control plane
initialize_control_plane() {
    log "INFO" "Initializing Kubernetes control plane..."
    
    # Set hostname
    log "INFO" "Setting hostname to $NODE_NAME"
    sudo hostnamectl set-hostname $NODE_NAME
    echo "127.0.0.1 $NODE_NAME" | sudo tee -a /etc/hosts
    
    # Initialize with kubeadm
    log "INFO" "Running kubeadm init with pod CIDR $POD_NETWORK_CIDR and API address $API_ADVERTISE_ADDRESS"
    
    # Create a kubeadm config file for more control
    cat <<EOF | sudo tee /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${API_ADVERTISE_ADDRESS}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${KUBERNETES_VERSION}
networking:
  podSubnet: ${POD_NETWORK_CIDR}
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
    
    # Execute kubeadm init with the config file
    if ! sudo kubeadm init --config=/tmp/kubeadm-config.yaml; then
        log "ERROR" "kubeadm init failed. Checking for common issues..."
        
        # Check for swap
        if grep -q "swap" /proc/swaps; then
            log "ERROR" "Swap is still enabled. Disabling swap and retrying..."
            sudo swapoff -a
            sudo sed -i '/swap/d' /etc/fstab
            sleep 2
            log "INFO" "Retrying kubeadm init..."
            if ! sudo kubeadm init --config=/tmp/kubeadm-config.yaml; then
                log "ERROR" "kubeadm init failed again after disabling swap"
                return 1
            fi
        else
            # Check for port conflicts
            if sudo netstat -tulpn | grep -q "6443"; then
                log "ERROR" "Port 6443 is already in use. Please check for other services using this port."
                return 1
            fi
            
            # Other unknown error
            log "ERROR" "kubeadm init failed for an unknown reason"
            return 1
        fi
    fi
    
    log "INFO" "Control plane initialized successfully"
    return 0
}

# Create a function to set up kubectl for the user
setup_kubectl() {
    log "INFO" "Setting up kubectl configuration..."
    
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Add kubectl to PATH if it's not already there
    if ! grep -q "KUBECONFIG" $HOME/.bashrc; then
        echo "export KUBECONFIG=$HOME/.kube/config" | tee -a $HOME/.bashrc
    fi
    
    # Source it for the current session
    export KUBECONFIG=$HOME/.kube/config
    
    # Verify kubectl works
    if ! kubectl get nodes &>/dev/null; then
        log "ERROR" "kubectl is not functioning properly"
        return 1
    fi
    
    log "INFO" "kubectl configured successfully"
    return 0
}

# Create a function to install CNI (Calico)
install_cni() {
    log "INFO" "Installing Calico CNI..."
    
    # Install the Tigera Calico operator
    if ! kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/tigera-operator.yaml; then
        log "ERROR" "Failed to install Tigera Calico operator"
        return 1
    fi
    
    # Wait for operator to start
    log "INFO" "Waiting for Tigera operator to start..."
    sleep 10
    
    # Apply Calico custom resources
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
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to apply Calico custom resources"
        return 1
    fi
    
    # Wait for Calico pods to be ready
    log "INFO" "Waiting for Calico pods to be ready (this may take a few minutes)..."
    
    # Try up to 10 times (with 30 second interval)
    for i in {1..10}; do
        if kubectl get pods -n calico-system 2>/dev/null | grep -q "Running"; then
            log "INFO" "Calico pods are starting to run"
            break
        fi
        log "INFO" "Waiting for Calico pods (attempt $i/10)..."
        sleep 30
    done
    
    # Final check for calico-system namespace
    if ! kubectl get namespace calico-system &>/dev/null; then
        log "WARNING" "Calico system namespace not found after waiting. CNI installation may not be complete."
        log "INFO" "You may need to check the status manually with 'kubectl get pods -A'"
    else
        log "INFO" "Calico CNI installed successfully"
    fi
    
    return 0
}

# Function to generate a join command
generate_join_command() {
    log "INFO" "Generating worker node join command..."
    
    JOIN_COMMAND=$(sudo kubeadm token create --print-join-command 2>/dev/null)
    
    if [ -z "$JOIN_COMMAND" ]; then
        log "ERROR" "Failed to generate join command"
        return 1
    fi
    
    log "INFO" "Join command generated successfully"
    return 0
}

# Function to verify cluster status
verify_cluster() {
    log "INFO" "Verifying cluster status..."
    
    # Wait for node to be ready
    log "INFO" "Waiting for master node to be ready..."
    local ready=false
    for i in {1..10}; do
        if kubectl get nodes | grep -q "Ready"; then
            ready=true
            break
        fi
        log "INFO" "Waiting for node to be ready (attempt $i/10)..."
        sleep 15
    done
    
    if [ "$ready" = true ]; then
        log "INFO" "Master node is ready"
    else
        log "WARNING" "Master node not ready after waiting. Please check status manually."
    fi
    
    # Check core components
    log "INFO" "Checking core components..."
    kubectl get pods -n kube-system
    
    return 0
}

# Function to clean up temporary files
cleanup() {
    log "INFO" "Cleaning up temporary files..."
    rm -f /tmp/kubeadm-config.yaml
    log "INFO" "Cleanup completed"
}

# Function to mark progress
mark_progress() {
    echo "$1" > $PROGRESS_FILE
}

# Function to get current progress
get_progress() {
    if [ -f $PROGRESS_FILE ]; then
        cat $PROGRESS_FILE
    else
        echo "none"
    fi
}

# Main script execution starts here

# Create log directory if it doesn't exist
sudo mkdir -p $(dirname $LOG_FILE)
sudo touch $LOG_FILE
sudo chown $(id -u):$(id -g) $LOG_FILE

# Print script info
log "INFO" "==============================================="
log "INFO" "Kubernetes Master Node Setup"
log "INFO" "-----------------------------------------------"
log "INFO" "This script will configure this machine as the"
log "INFO" "Kubernetes control plane node"
log "INFO" "Log file: $LOG_FILE"
log "INFO" "==============================================="

# Check for resume flag
RESUME=false
if [ "$1" = "--resume" ]; then
    RESUME=true
    log "INFO" "Resuming from previous execution..."
    log "INFO" "Last successful step: $(get_progress)"
fi

# Set the trap for error handling
trap 'handle_error $LINENO' ERR

# Start the installation process based on progress
CURRENT_PROGRESS=$(get_progress)

# Check prerequisites only if not resuming or if at the beginning
if [ "$CURRENT_PROGRESS" = "none" ] || [ "$CURRENT_PROGRESS" = "prerequisites_checked" ]; then
    check_system_requirements
    check_existing_installation
    mark_progress "prerequisites_checked"
fi

# Update package list and install prerequisites
if [ "$CURRENT_PROGRESS" = "none" ] || [ "$CURRENT_PROGRESS" = "prerequisites_checked" ]; then
    log "INFO" "[1/8] Updating system and installing prerequisites..."
    sudo apt-get update || { log "ERROR" "Failed to update package list"; exit 1; }
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg || \
        { log "ERROR" "Failed to install prerequisites"; exit 1; }
    mark_progress "prerequisites_installed"
fi

# Disable swap (required for Kubernetes)
if [ "$CURRENT_PROGRESS" = "prerequisites_installed" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "swap_disabled" ]; then
    log "INFO" "[2/8] Disabling swap..."
    sudo swapoff -a || log "WARNING" "Failed to disable swap with swapoff"
    sudo sed -i '/swap/d' /etc/fstab || log "WARNING" "Failed to remove swap from fstab"
    
    # Double-check swap is off
    if grep -q "swap" /proc/swaps; then
        log "WARNING" "Swap is still enabled despite attempts to disable it"
        read -p "Continue anyway? This might cause problems. (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "ERROR" "Aborted due to enabled swap"
            exit 1
        fi
    else
        log "INFO" "Swap is successfully disabled"
    fi
    mark_progress "swap_disabled"
fi

# Configure kernel modules and sysctl
if [ "$CURRENT_PROGRESS" = "swap_disabled" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "kernel_configured" ]; then
    log "INFO" "[3/8] Configuring kernel modules and system settings..."
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay || log "WARNING" "Failed to load overlay module"
    sudo modprobe br_netfilter || log "WARNING" "Failed to load br_netfilter module"

    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sudo sysctl --system || log "WARNING" "Failed to apply sysctl settings"
    
    # Verify settings were applied
    if ! sysctl net.bridge.bridge-nf-call-iptables | grep -q "1"; then
        log "WARNING" "net.bridge.bridge-nf-call-iptables is not set to 1"
    fi
    mark_progress "kernel_configured"
fi

# Install containerd as container runtime
if [ "$CURRENT_PROGRESS" = "kernel_configured" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "containerd_installed" ]; then
    log "INFO" "[4/8] Installing containerd as container runtime..."
    
    # Create required directories
    sudo mkdir -p /etc/apt/keyrings
    
    # Add Docker repository
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || \
        { log "ERROR" "Failed to download Docker GPG key"; exit 1; }
    
    # Detect Ubuntu version
    UBUNTU_VERSION=$(lsb_release -cs)
    log "INFO" "Detected Ubuntu version: $UBUNTU_VERSION"
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_VERSION stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || \
        { log "ERROR" "Failed to add Docker repository"; exit 1; }
    
    # Update and install containerd
    sudo apt-get update || { log "ERROR" "Failed to update package list after adding Docker repository"; exit 1; }
    sudo apt-get install -y containerd.io || { log "ERROR" "Failed to install containerd"; exit 1; }
    
    # Configure containerd to use systemd cgroup driver
    mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null || \
        { log "ERROR" "Failed to generate containerd config"; exit 1; }
    sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml || \
        { log "ERROR" "Failed to configure containerd for systemd cgroups"; exit 1; }
    sudo systemctl restart containerd || { log "ERROR" "Failed to restart containerd"; exit 1; }
    sudo systemctl enable containerd || { log "ERROR" "Failed to enable containerd"; exit 1; }
    
    # Verify containerd is running
    if ! systemctl is-active --quiet containerd; then
        log "ERROR" "containerd is not running after installation"
        exit 1
    fi
    mark_progress "containerd_installed"
fi

# Install Kubernetes components
if [ "$CURRENT_PROGRESS" = "containerd_installed" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "kubernetes_installed" ]; then
    log "INFO" "[5/8] Installing Kubernetes components (kubeadm, kubelet, kubectl)..."
    
    # Create required directories
    sudo mkdir -p /etc/apt/keyrings
    
    # Add Kubernetes repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/Release.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || \
        { log "ERROR" "Failed to download Kubernetes GPG key"; exit 1; }
    
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list || \
        { log "ERROR" "Failed to add Kubernetes repository"; exit 1; }
    
    # Update and install Kubernetes components
    sudo apt-get update || { log "ERROR" "Failed to update package list after adding Kubernetes repository"; exit 1; }
    
    # Try to install exact version, if it fails, try without version specifier
    if ! sudo apt-get install -y kubelet=${KUBERNETES_VERSION}-* kubeadm=${KUBERNETES_VERSION}-* kubectl=${KUBERNETES_VERSION}-*; then
        log "WARNING" "Failed to install Kubernetes ${KUBERNETES_VERSION}-*, trying without version specifier"
        sudo apt-get install -y kubelet kubeadm kubectl || { log "ERROR" "Failed to install Kubernetes components"; exit 1; }
        
        # Get the actual installed version for logging
        INSTALLED_VERSION=$(kubeadm version -o short 2>/dev/null | cut -d'v' -f2)
        log "INFO" "Installed Kubernetes version: $INSTALLED_VERSION (instead of requested $KUBERNETES_VERSION)"
    else
        log "INFO" "Installed Kubernetes version: $KUBERNETES_VERSION"
    fi
    
    # Hold packages to prevent unexpected upgrades
    sudo apt-mark hold kubelet kubeadm kubectl || log "WARNING" "Failed to hold Kubernetes packages"
    
    # Verify binaries are installed and in path
    if ! command -v kubeadm &>/dev/null || ! command -v kubelet &>/dev/null || ! command -v kubectl &>/dev/null; then
        log "ERROR" "Kubernetes binaries are not properly installed"
        exit 1
    fi
    mark_progress "kubernetes_installed"
fi

# Initialize the Kubernetes control-plane node
if [ "$CURRENT_PROGRESS" = "kubernetes_installed" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "control_plane_initialized" ]; then
    log "INFO" "[6/8] Initializing Kubernetes control plane..."
    initialize_control_plane || { log "ERROR" "Failed to initialize control plane"; exit 1; }
    mark_progress "control_plane_initialized"
fi

# Set up kubeconfig for the user
if [ "$CURRENT_PROGRESS" = "control_plane_initialized" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "kubectl_configured" ]; then
    log "INFO" "[7/8] Setting up kubectl configuration..."
    setup_kubectl || { log "ERROR" "Failed to set up kubectl"; exit 1; }
    mark_progress "kubectl_configured"
fi

# Install Calico network plugin
if [ "$CURRENT_PROGRESS" = "kubectl_configured" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "cni_installed" ]; then
    log "INFO" "[8/8] Installing Calico as the pod network plugin..."
    install_cni || { log "ERROR" "Failed to install Calico CNI"; exit 1; }
    mark_progress "cni_installed"
fi

# Generate the join command for worker nodes
log "INFO" "[+] Generating worker node join command..."
generate_join_command || { log "WARNING" "Failed to generate join command. You may need to generate it manually."; }

# Verify the cluster status
log "INFO" "[+] Verifying cluster status..."
verify_cluster

# Cleanup
cleanup

# Success message
log "INFO" "-----------------------------------------------------------"
log "INFO" "✅ Kubernetes control plane setup complete!"
if [ ! -z "$JOIN_COMMAND" ]; then
    log "INFO" "📋 Use the following command on your worker node to join the cluster:"
    log "INFO" "$JOIN_COMMAND"
fi
log "INFO" "-----------------------------------------------------------"

# Verify the cluster status with kubectl
kubectl get nodes

log "INFO" "Kubernetes master node setup completed successfully"
mark_progress "setup_completed"

exit 0 