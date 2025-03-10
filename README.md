# Kubernetes Cluster Setup for Xubuntu on Macbook Air

This repository contains scripts to configure a Kubernetes cluster on two Macbook Airs running Xubuntu.

## Prerequisites

- Two Macbook Air laptops running Xubuntu
- Both machines connected to the same network
- SSH access between the machines
- Sudo privileges on both machines

## Architecture

The setup consists of:
- One master/control-plane node
- One worker node

## Setup Instructions

### 1. Prepare both machines

- Download the scripts to both machines
- Make the scripts executable:
  ```bash
  chmod +x master_node_setup.sh worker_node_setup.sh setup_ssh_access.sh
  ```

### 2. Set up the master node

1. On the first Macbook Air (master node), run:
   ```bash
   ./master_node_setup.sh
   ```

2. The script will install all necessary components and initialize the Kubernetes control plane

3. At the end of the script, it will output a `kubeadm join` command. **Save this command** as you'll need it for the worker node.

### 3. Set up the worker node

1. On the second Macbook Air (worker node), run:
   ```bash
   ./worker_node_setup.sh
   ```

2. After the script completes, run the `kubeadm join` command that was output from the master node setup:
   ```bash
   sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
   ```

### 4. Configure SSH access to the master node

To enable SSH access to the master node from your personal PC:

1. On the master node, run:
   ```bash
   ./setup_ssh_access.sh
   ```

2. The script will:
   - Install the SSH server
   - Configure SSH for secure remote access
   - Open the necessary firewall ports
   - Display connection information

3. Connect from your personal PC using:
   ```bash
   ssh username@master-node-ip
   ```

4. For more secure access, set up SSH key authentication:
   - Generate SSH keys on your personal PC (if you don't have them already)
   - Copy your public key to the master node
   - Optionally disable password authentication

### 5. Verify the cluster

On the master node, run:
```bash
kubectl get nodes
```

You should see both nodes listed, with the master node showing status `Ready` and role `control-plane,master`, and the worker node showing status `Ready` and no special role.

## Remote Kubernetes Administration

After setting up SSH access, you can administer your Kubernetes cluster remotely from your personal PC:

1. Install kubectl on your personal PC

2. Copy the Kubernetes configuration from the master node:
   ```bash
   mkdir -p ~/.kube
   scp username@master-node-ip:~/.kube/config ~/.kube/config
   ```

3. Test your connection:
   ```bash
   kubectl get nodes
   ```

## Customization

You can modify the following variables in the scripts before running them:

- `KUBERNETES_VERSION` - Kubernetes version to install (default: 1.27.0)
- `POD_NETWORK_CIDR` - CIDR for pod networking (default: 10.244.0.0/16)
- `NODE_NAME` - Hostname for each node
- `SSH_PORT` - SSH port (default: 22) in setup_ssh_access.sh

## Troubleshooting

### If the join command expires

If the join token has expired, you can generate a new one on the master node:
```bash
sudo kubeadm token create --print-join-command
```

### Network issues

If pods cannot communicate between nodes:
1. Verify that nodes can ping each other
2. Check that the Calico pods are running:
   ```bash
   kubectl get pods -n kube-system | grep calico
   ```

### SSH connection issues

If you can't connect to the master node via SSH:
1. Verify the SSH service is running: `systemctl status ssh`
2. Check firewall settings: `sudo ufw status` or `sudo iptables -L`
3. Verify you're using the correct IP address and username

### Reset the cluster

If you need to start over, on all nodes run:
```bash
sudo kubeadm reset
sudo rm -rf $HOME/.kube
```

## Security Notes

- This setup is designed for learning and testing purposes
- For production environments, additional security measures should be implemented:
  - Enable RBAC with proper user accounts
  - Configure network policies
  - Set up proper TLS certificates
  - Use a firewall to restrict access to the API server
  - Regularly update all components
  - Use SSH key authentication and disable password authentication

## Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Calico Documentation](https://docs.projectcalico.org/)
- [SSH Security Best Practices](https://www.ssh.com/academy/ssh/security) 