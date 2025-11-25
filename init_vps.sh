#!/usr/bin/env bash
set -e

# ==== 可修改参数 ====
USERNAME="aleta"
SSH_PORT=21357
LOCAL_SSH_KEY="$HOME/.ssh/id_rsa.pub"
# ====================

echo "🚀 初始化 VPS..."

# 更新系统
sudo apt update && sudo apt upgrade -y

# 创建用户
sudo adduser --disabled-password --gecos "" $USERNAME
echo "$USERNAME:$(openssl rand -base64 12)" | sudo chpasswd

# 加入 sudo 并免密
sudo usermod -aG sudo $USERNAME
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USERNAME >/dev/null

# 配置 SSH Key
sudo mkdir -p /home/$USERNAME/.ssh
sudo cp "$LOCAL_SSH_KEY" /home/$USERNAME/.ssh/authorized_keys
sudo chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
sudo chmod 700 /home/$USERNAME/.ssh
sudo chmod 600 /home/$USERNAME/.ssh/authorized_keys

# 修改 SSH 端口（保留 root 登录）
sudo sed -i 's/^Port /#Port /' /etc/ssh/sshd_config
echo "Port $SSH_PORT" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh

# 安装防火墙并启用
sudo apt install -y ufw fail2ban
sudo ufw allow $SSH_PORT/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# 启用 fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

echo "✅ VPS 初始化完成！"
echo "请使用命令登录：ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
