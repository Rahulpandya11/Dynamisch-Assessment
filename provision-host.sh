#!/bin/bash
# provision-host.sh
# Bootstraps a fresh Ubuntu 26.04 EC2 instance for the Magento stack.
# Run once as root or with sudo: sudo bash scripts/provision-host.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo ">>> System update"
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl wget git unzip make vim htop \
    ca-certificates gnupg lsb-release \
    ufw fail2ban net-tools openssl jq apache2-utils

echo ">>> Create group clp (gid 1001) and user test-ssh (uid 1001)"
groupadd -g 1001 clp 2>/dev/null || echo "group clp already exists"
useradd -m -u 1001 -g clp -s /bin/bash test-ssh 2>/dev/null || echo "user test-ssh already exists"
usermod -aG sudo test-ssh

# Allow sudo without password so scripts can run unattended
echo "test-ssh ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/test-ssh
chmod 440 /etc/sudoers.d/test-ssh

# Copy SSH authorised keys from ubuntu user so test-ssh can login via key
mkdir -p /home/test-ssh/.ssh
if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
    cp /home/ubuntu/.ssh/authorized_keys /home/test-ssh/.ssh/authorized_keys
fi
chown -R test-ssh:clp /home/test-ssh/.ssh
chmod 700 /home/test-ssh/.ssh
chmod 600 /home/test-ssh/.ssh/authorized_keys 2>/dev/null || true

echo ">>> Disable SSH password authentication"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

echo ">>> Install Docker Engine"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# Add both ubuntu and test-ssh to the docker group
usermod -aG docker ubuntu   2>/dev/null || true
usermod -aG docker test-ssh

echo ">>> Create 4 GB swap file"
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo ">>> Kernel tuning"
cat >> /etc/sysctl.conf <<'SYSCTL'
# Swap only when RAM is nearly exhausted
vm.swappiness=10
vm.vfs_cache_pressure=50
# Required by Elasticsearch
vm.max_map_count=262144
# Higher file descriptor limit
fs.file-max=65536
SYSCTL
sysctl -p

cat >> /etc/security/limits.conf <<'LIMITS'
test-ssh soft nofile 65536
test-ssh hard nofile 65536
root     soft nofile 65536
root     hard nofile 65536
LIMITS

echo ">>> UFW firewall — allow only SSH, HTTP, HTTPS"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP — redirected to HTTPS'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

echo ">>> Enable fail2ban"
systemctl enable fail2ban
systemctl start fail2ban

echo ">>> Create project directory"
mkdir -p /opt/magento
chown -R test-ssh:clp /opt/magento
chmod 755 /opt/magento

echo ""
echo ">>> Provisioning complete."
echo "    Reboot recommended to apply all kernel parameters."
echo "    Then log in as test-ssh and run: make install"
