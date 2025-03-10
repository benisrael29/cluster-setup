#!/bin/bash
# SSH Access Setup Script for Kubernetes Master Node
# This script configures SSH access to allow connections from your personal PC
# on the same local network only

set -e

# Variables - modify as needed
SSH_PORT=22
ALLOW_PASSWORD_AUTH=yes  # Change to "no" if you want to enforce key-based authentication only

# Print script info
echo "==============================================="
echo "SSH Access Setup for Kubernetes Master Node"
echo "-----------------------------------------------"
echo "This script will configure SSH access to allow"
echo "connections from your personal PC on the same local network"
echo "==============================================="

# Install SSH server if not already installed
echo "[1/6] Ensuring SSH server is installed..."
sudo apt-get update
sudo apt-get install -y openssh-server

# Start and enable SSH service
echo "[2/6] Starting and enabling SSH service..."
sudo systemctl enable ssh
sudo systemctl start ssh

# Configure SSH
echo "[3/6] Configuring SSH server..."
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo tee /etc/ssh/sshd_config > /dev/null <<EOF
# SSH Server Configuration
Port $SSH_PORT
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Logging
SyslogFacility AUTH
LogLevel INFO

# Authentication
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $ALLOW_PASSWORD_AUTH
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Additional security settings
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
EOF

# Detect local network information
echo "[4/6] Detecting local network information..."
IP_ADDRESS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
if [ -z "$IP_ADDRESS" ]; then
    echo "Error: Could not detect local IP address. Please check your network configuration."
    exit 1
fi

# Extract network information
IP_PREFIX=$(echo $IP_ADDRESS | cut -d. -f1,2,3)
NETWORK_CIDR="${IP_PREFIX}.0/24"

echo "Detected local network: $NETWORK_CIDR"
echo "This script will restrict SSH access to only this network."

# Configure firewall to allow SSH only from local network
echo "[5/6] Configuring firewall to allow SSH connections only from local network ($NETWORK_CIDR)..."
if command -v ufw &> /dev/null; then
    # Check if UFW is active
    if ! sudo ufw status | grep -q "Status: active"; then
        echo "Enabling UFW firewall..."
        sudo ufw enable
    fi
    
    # Delete any existing SSH rules
    sudo ufw status numbered | grep $SSH_PORT/tcp | cut -d"[" -f2 | cut -d"]" -f1 | sort -r | xargs -I{} sudo ufw delete {}
    
    # Add new rule to allow SSH only from local network
    sudo ufw allow from $NETWORK_CIDR to any port $SSH_PORT proto tcp
    
    # Show UFW status
    sudo ufw status verbose
elif command -v iptables &> /dev/null; then
    # Clear existing SSH rules
    sudo iptables -D INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || true
    
    # Add new rule to allow SSH only from local network
    sudo iptables -A INPUT -p tcp -s $NETWORK_CIDR --dport $SSH_PORT -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport $SSH_PORT -j DROP
    
    # Show iptables rules
    sudo iptables -L INPUT -n -v | grep tcp
    
    # Make iptables rules persistent (if possible)
    if command -v iptables-save &> /dev/null; then
        sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        sudo iptables-save | sudo tee /etc/iptables.rules 2>/dev/null || \
        echo "Warning: Could not save iptables rules. They will be lost on reboot."
    fi
else
    echo "No firewall detected. Please manually ensure SSH port $SSH_PORT is restricted to $NETWORK_CIDR."
fi

# Restart SSH service to apply changes
echo "[6/6] Restarting SSH service to apply changes..."
sudo systemctl restart ssh

# Display connection information
echo "==============================================="
echo "SSH access has been configured!"
echo "-----------------------------------------------"
USERNAME=$(whoami)
echo "You can now connect to this master node using:"
echo "ssh $USERNAME@$IP_ADDRESS -p $SSH_PORT"
echo
echo "⚠️ IMPORTANT: SSH access is ONLY allowed from devices on your local network ($NETWORK_CIDR)"
echo "Connections from other networks or the internet will be blocked."
echo
echo "If you want to use SSH key authentication:"
echo "1. On your personal PC, generate an SSH key pair if you don't have one:"
echo "   ssh-keygen -t ed25519 -C \"your_email@example.com\""
echo
echo "2. Copy your public key to this server:"
echo "   ssh-copy-id -p $SSH_PORT $USERNAME@$IP_ADDRESS"
echo "   OR manually add your public key to ~/.ssh/authorized_keys"
echo
echo "3. If you want to disable password authentication after setting up keys,"
echo "   edit this script to set ALLOW_PASSWORD_AUTH=no and run it again"
echo "===============================================" 