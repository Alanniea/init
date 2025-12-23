#!/bin/bash

# 检查是否以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "请使用 sudo 或 root 用户运行此脚本"
   exit 1
fi

echo "--- Ubuntu VPS 一键初始化脚本 ---"

# 1. 交互式获取参数
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

read -p "请粘贴您的本地公钥 (id_rsa.pub 的内容): " SSH_KEY
if [ -z "$SSH_KEY" ]; then
    echo "错误：必须提供公钥才能继续。"
    exit 1
fi

# 生成 16 位随机密码
RANDOM_PASS=$(openssl rand -base64 12)

echo "--- 正在开始配置... ---"

# 2. 更新系统
apt update && apt upgrade -y

# 3. 创建用户并设置免密 sudo
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"

# 4. 配置 SSH 公钥登录
mkdir -p "/home/$USERNAME/.ssh"
echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
chmod 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"

# 5. 修改 SSH 端口并禁用密码登录
sed -i "s/^#\?Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config # 保留 root 登录但仅限密钥（视需求可改为 no）
systemctl restart ssh

# 6. 安装并配置 Fail2ban
apt install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
EOF
systemctl restart fail2ban

# 7. 配置 UFW 防火墙
apt install -y ufw
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "------------------------------------------------"
echo "✅ 初始化完成！"
echo "------------------------------------------------"
echo "用户名: $USERNAME"
echo "临时密码: $RANDOM_PASS (已配置免密 sudo，此密码仅作备份)"
echo "SSH 端口: $SSH_PORT"
echo "防火墙已放行: $SSH_PORT, 80, 443"
echo "------------------------------------------------"
echo "请尝试在新终端登录: ssh -p $SSH_PORT $USERNAME@您的服务器IP"
