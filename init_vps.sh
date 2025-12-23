#!/bin/bash

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 用户运行此脚本"
   exit 1
fi

echo "--- Ubuntu VPS 初始化脚本 ---"

# 1. 交互式获取参数
read -p "请输入要创建的用户名 [默认: aleta]: " NEW_USER
NEW_USER=${NEW_USER:-aleta}

read -p "请输入 SSH 端口号 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

# 提示输入公钥
echo "请粘贴您的本地公钥 (~/.ssh/id_rsa.pub 的内容):"
read -r SSH_PUB_KEY

if [[ -z "$SSH_PUB_KEY" ]]; then
    echo "错误：必须提供 SSH 公钥才能继续。"
    exit 1
fi

# 2. 生成随机密码
RANDOM_PASS=$(openssl rand -base64 12)

# 3. 更新系统
apt update && apt upgrade -y

# 4. 创建用户并设置
useradd -m -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$NEW_USER"

# 设置免密 sudo
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"

# 5. 配置 SSH 密钥登录
USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_PUB_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. 修改 SSH 配置
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart ssh

# 7. 安装并配置 Fail2ban
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

# 8. 配置 UFW 防火墙
apt install -y ufw
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# --- 结果输出 ---
clear
echo "========================================"
echo "          VPS 初始化完成！"
echo "========================================"
echo "用户名     : $NEW_USER"
echo "随机密码   : $RANDOM_PASS"
echo "SSH 端口   : $SSH_PORT"
echo "管理权限   : 已开启免密 sudo"
echo "防火墙     : 已放行 $SSH_PORT, 80, 443"
echo "Fail2ban   : 已启动并监控端口 $SSH_PORT"
echo "========================================"
echo "请使用以下命令连接："
echo "ssh -p $SSH_PORT $NEW_USER@your_server_ip"
echo "========================================"
