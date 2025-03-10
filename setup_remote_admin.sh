#!/bin/bash
# Remote Kubernetes Administration Setup Script
# This script prepares the master node to allow remote administration
# from a personal PC and provides instructions for the personal PC side.

set -e

# Variables - modify as needed
KUBE_DIRECTORY="$HOME/.kube"
KUBE_CONFIG="$KUBE_DIRECTORY/config"
REMOTE_USER=$(whoami)
REMOTE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)

# Print script info
echo "==============================================="
echo "Remote Kubernetes Administration Setup"
echo "-----------------------------------------------"
echo "This script prepares your master node for"
echo "remote administration from your personal PC"
echo "==============================================="

# Verify that kubernetes is set up
if [ ! -f "$KUBE_CONFIG" ]; then
    echo "Error: Kubernetes configuration not found at $KUBE_CONFIG"
    echo "Please ensure you've successfully set up the Kubernetes master node first."
    exit 1
fi

# Ensure that SSH is properly configured
echo "[1/3] Verifying SSH configuration..."
if ! systemctl is-active --quiet ssh; then
    echo "SSH service is not running. Consider running the setup_ssh_access.sh script first."
    exit 1
else
    echo "SSH service is running."
fi

# Create a copy of the kube config that can be transported
echo "[2/3] Preparing Kubernetes configuration for remote access..."
TRANSPORTABLE_CONFIG="$HOME/kube-config-remote"
cp "$KUBE_CONFIG" "$TRANSPORTABLE_CONFIG"

# Fix permissions for security
chmod 600 "$TRANSPORTABLE_CONFIG"

# Replace localhost references with the actual IP
sed -i "s/127.0.0.1/$REMOTE_IP/g" "$TRANSPORTABLE_CONFIG"

# Enable kubectl proxy to allow remote API access (optional)
echo "[3/3] Setting up kubectl proxy for remote API access..."
cat > "$HOME/start_kube_proxy.sh" << EOF
#!/bin/bash
# Start kubectl proxy to allow remote API access
kubectl proxy --address='0.0.0.0' --port=8001 --accept-hosts='.*'
EOF

chmod +x "$HOME/start_kube_proxy.sh"

# Display instructions for the personal PC
echo "==============================================="
echo "Remote administration setup complete!"
echo "==============================================="
echo
echo "NEXT STEPS ON YOUR PERSONAL PC:"
echo
echo "1. Install kubectl on your personal PC"
echo "   - For Windows: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/"
echo "   - For macOS: https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/"
echo "   - For Linux: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
echo
echo "2. Create the .kube directory on your personal PC:"
echo "   mkdir -p ~/.kube"
echo
echo "3. Copy the Kubernetes config from this master node to your personal PC:"
echo "   scp $REMOTE_USER@$REMOTE_IP:$TRANSPORTABLE_CONFIG ~/.kube/config"
echo
echo "4. Test the connection from your personal PC:"
echo "   kubectl get nodes"
echo
echo "5. Optional: Access the Kubernetes dashboard remotely"
echo "   - On the master node, run: $HOME/start_kube_proxy.sh"
echo "   - On your personal PC, you can access the API at: http://$REMOTE_IP:8001/api/v1"
echo
echo "SECURITY NOTE: The transportable config file contains authentication details."
echo "Keep it secure and delete it after copying to your personal PC with:"
echo "  rm $TRANSPORTABLE_CONFIG"
echo "===============================================" 