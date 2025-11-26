#!/usr/bin/env bash
set -e

echo "🚀 Ubuntu VPS 一键初始化脚本"

# -------------------------------
# 1️⃣ 确认运行用户为 root
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本"
    exit 1
fi

# -------------------------------
# 2️⃣ 创建新用户并设置随机密码
USERNAME="aleta"
PASSWORD=$(openssl rand -base64 12)
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "✅ 用户 $USERNAME 创建完成，随机密码：$PASSWORD"

# -------------------------------
# 3️⃣ 配置免密 sudo
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME
echo "✅ 免密 sudo 已启用"

# -------------------------------
# 4️⃣ 配置 SSH 公钥登录
SSH_DIR="/home/$USERNAME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
cat ~/.ssh/id_rsa.pub > "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R $USERNAME:$USERNAME "$SSH_DIR"
echo "✅ 公钥登录已配置"

# -------------------------------
# 5️⃣ 修改 SSH 端口
read -p "是否修改 SSH 端口为 21357? (y/n) " modify_ssh
if [[ "$modify_ssh" =~ ^[Yy]$ ]]; then
    sed -i "s/#Port 22/Port 21357/" /etc/ssh/sshd_config || echo "Port 21357" >> /etc/ssh/sshd_config
    systemctl restart sshd
    echo "✅ SSH 端口已修改为 21357"
fi

# -------------------------------
# 6️⃣ 安装 fail2ban
read -p "是否安装 fail2ban? (y/n) " install_fail2ban
if [[ "$install_fail2ban" =~ ^[Yy]$ ]]; then
    apt update && apt install -y fail2ban
    systemctl enable --now fail2ban
    echo "✅ fail2ban 安装完成"
fi

# -------------------------------
# 7️⃣ 配置防火墙
read -p "是否配置 UFW 放行 80/443? (y/n) " setup_ufw
if [[ "$setup_ufw" =~ ^[Yy]$ ]]; then
    apt install -y ufw
    ufw allow 80
    ufw allow 443
    ufw allow 21357/tcp
    ufw --force enable
    echo "✅ 防火墙已配置"
fi

# -------------------------------
echo "🎉 VPS 初始化完成！"
echo "用户名: $USERNAME"
echo "随机密码: $PASSWORD"
echo "SSH 端口: 21357"
