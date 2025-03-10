#!/bin/bash
# Kubernetes Worker Node Setup Script for Xubuntu on Macbook Air
# This script configures the second Macbook Air as a Kubernetes worker node

# Ensure script fails on any error
set -e

# Script name for logging
SCRIPT_NAME="worker_node_setup.sh"

# Variables - modify as needed
KUBERNETES_VERSION="1.27.0"
NODE_NAME="worker-node-1"
MIN_RAM_MB=2048
MIN_CPU_CORES=2
MIN_DISK_GB=20
LOG_FILE="/var/log/k8s_worker_setup.log"
PROGRESS_FILE="/tmp/k8s_worker_setup_progress"

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
        read -p "Do you want to proceed and potentially disrupt the existing setup? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Installation aborted by user"
            exit 0
        fi
    fi
    
    log "INFO" "Existing installation check completed"
    return 0
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

# Function to verify connectivity to master node
verify_master_connectivity() {
    log "INFO" "Please enter the Kubernetes master node IP address to verify connectivity:"
    read -p "Master IP: " MASTER_IP
    
    if [ -z "$MASTER_IP" ]; then
        log "ERROR" "No IP address provided. Skipping connectivity check."
        return 0
    fi
    
    log "INFO" "Checking connectivity to master node at $MASTER_IP..."
    
    # Check if the master node is reachable
    if ! ping -c 1 $MASTER_IP &>/dev/null; then
        log "WARNING" "Cannot ping master node at $MASTER_IP"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "ERROR" "Aborted due to connectivity issues with master node"
            exit 1
        fi
    else
        log "INFO" "Successfully pinged master node at $MASTER_IP"
        
        # Try to check if the Kubernetes API port is open
        if ! nc -z -w 5 $MASTER_IP 6443 &>/dev/null; then
            log "WARNING" "Cannot connect to Kubernetes API port 6443 on master node $MASTER_IP"
            log "WARNING" "This might indicate that the master node is not properly set up yet"
            read -p "Continue anyway? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "ERROR" "Aborted due to API connectivity issues with master node"
                exit 1
            fi
        else
            log "INFO" "Successfully connected to Kubernetes API port on master node"
        fi
    fi
    
    return 0
}

# Create a function to check hostname and set it if needed
configure_hostname() {
    log "INFO" "Configuring hostname..."
    
    # Check if hostname is already set to desired value
    if [ "$(hostname)" = "$NODE_NAME" ]; then
        log "INFO" "Hostname is already set to $NODE_NAME"
    else
        log "INFO" "Setting hostname to $NODE_NAME"
        sudo hostnamectl set-hostname $NODE_NAME
        echo "127.0.0.1 $NODE_NAME" | sudo tee -a /etc/hosts
    fi
    
    log "INFO" "Hostname configured successfully"
    return 0
}

# Main script execution starts here

# Create log directory if it doesn't exist
sudo mkdir -p $(dirname $LOG_FILE)
sudo touch $LOG_FILE
sudo chown $(id -u):$(id -g) $LOG_FILE

# Print script info
log "INFO" "==============================================="
log "INFO" "Kubernetes Worker Node Setup"
log "INFO" "-----------------------------------------------"
log "INFO" "This script will configure this machine as a"
log "INFO" "Kubernetes worker node"
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
    verify_master_connectivity
    mark_progress "prerequisites_checked"
fi

# Update package list and install prerequisites
if [ "$CURRENT_PROGRESS" = "prerequisites_checked" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "prerequisites_installed" ]; then
    log "INFO" "[1/6] Updating system and installing prerequisites..."
    sudo apt-get update || { log "ERROR" "Failed to update package list"; exit 1; }
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg netcat-openbsd || \
        { log "ERROR" "Failed to install prerequisites"; exit 1; }
    mark_progress "prerequisites_installed"
fi

# Disable swap (required for Kubernetes)
if [ "$CURRENT_PROGRESS" = "prerequisites_installed" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "swap_disabled" ]; then
    log "INFO" "[2/6] Disabling swap..."
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
    log "INFO" "[3/6] Configuring kernel modules and system settings..."
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
    log "INFO" "[4/6] Installing containerd as container runtime..."
    
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
    log "INFO" "[5/6] Installing Kubernetes components (kubeadm, kubelet, kubectl)..."
    
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

# Configure hostname
if [ "$CURRENT_PROGRESS" = "kubernetes_installed" ] || [ "$RESUME" = true -a "$CURRENT_PROGRESS" = "hostname_configured" ]; then
    log "INFO" "[6/6] Setting hostname..."
    configure_hostname || { log "ERROR" "Failed to configure hostname"; exit 1; }
    mark_progress "hostname_configured"
fi

# Provide instructions for joining the cluster
log "INFO" "==============================================="
log "INFO" "Worker node preparation complete!"
log "INFO" "==============================================="
log "INFO" ""
log "INFO" "To join this node to your Kubernetes cluster, run the 'kubeadm join' command"
log "INFO" "that was output when you initialized the control plane node."
log "INFO" ""
log "INFO" "The command should look similar to:"
log "INFO" "sudo kubeadm join <MASTER_IP>:6443 --token <TOKEN> \\"
log "INFO" "    --discovery-token-ca-cert-hash sha256:<HASH>"
log "INFO" ""
log "INFO" "If you don't have the join command, you can generate a new one on the master node with:"
log "INFO" "sudo kubeadm token create --print-join-command"
log "INFO" ""
log "INFO" "Once you run this command, go back to your master node and verify"
log "INFO" "that the new node has joined with: kubectl get nodes"
log "INFO" "==============================================="

# Instructions for if the join command fails
log "INFO" "If the join command fails, here are some troubleshooting tips:"
log "INFO" "1. Ensure both nodes are on the same network"
log "INFO" "2. Check firewall settings (ports 6443, 10250, and 10251 should be open)"
log "INFO" "3. Verify that the master node's API server is running"
log "INFO" "4. Make sure the token hasn't expired (tokens expire after 24 hours by default)"
log "INFO" "5. If needed, run 'sudo kubeadm reset' to start fresh, then try joining again"

mark_progress "setup_completed"
exit 0 