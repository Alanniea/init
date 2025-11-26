#!/usr/bin/env bash
set -e

# -----------------------------
# 交互确认
echo "⚠️  本脚本将初始化 Ubuntu VPS"
read -p "确认继续吗？(yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "已取消"
    exit 1
fi

# -----------------------------
# 参数
USERNAME="aleta"
SSH_PORT=21357
PUB_KEY="$HOME/.ssh/id_rsa.pub"

# -----------------------------
# 生成随机密码
PASSWORD=$(openssl rand -base64 16)
echo "🔑 为用户 $USERNAME 生成随机密码: $PASSWORD"

# -----------------------------
# 更新系统 & 安装必要工具
echo "📦 更新系统并安装必要工具..."
apt update && apt upgrade -y
apt install -y sudo ufw fail2ban curl

# -----------------------------
# 创建用户并设置密码 & sudo
if id "$USERNAME" &>/dev/null; then
    echo "用户 $USERNAME 已存在，跳过创建"
else
    echo "👤 创建用户 $USERNAME"
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    usermod -aG sudo "$USERNAME"
fi

# -----------------------------
# 配置 SSH
echo "🔐 配置 SSH..."
mkdir -p /home/$USERNAME/.ssh
cp "$PUB_KEY" /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys

# 修改 SSH 端口并禁用 root 登录
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
systemctl restart sshd

# -----------------------------
# 配置防火墙
echo "🛡️ 配置防火墙..."
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# -----------------------------
# 启用 fail2ban
echo "🛡️ 启用 fail2ban..."
systemctl enable fail2ban
systemctl restart fail2ban

# -----------------------------
# 输出完成信息
echo "✅ 初始化完成!"
echo "用户: $USERNAME"
echo "SSH端口: $SSH_PORT"
echo "随机密码: $PASSWORD"
echo "请使用公钥登录或密码登录后立即修改密码."
