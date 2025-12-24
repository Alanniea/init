#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行此脚本"
  exit
fi

echo "--- VPS 一键初始化脚本 ---"

# 1. 交互式获取参数
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

# 2. 生成随机密码
PASSWORD=$(openssl rand -base64 12)

# 3. 创建用户并设置免密 sudo
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/90-init-users

# 4. 配置 SSH 公钥登录
# 请确保执行脚本前，你已准备好将本地公钥内容贴入提示框
mkdir -p /home/"$USERNAME"/.ssh
chmod 700 /home/"$USERNAME"/.ssh
echo "请粘贴你的本地公钥 (~/.ssh/id_rsa.pub 的内容):"
read -r PUBLIC_KEY
echo "$PUBLIC_KEY" > /home/"$USERNAME"/.ssh/authorized_keys
chmod 600 /home/"$USERNAME"/.ssh/authorized_keys
chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/.ssh

# 5. 修改 SSH 配置 (端口、禁止 root 登录、禁用密码登录)
sed -i "s/^#\?Port.*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart ssh

# 6. 安装 fail2ban
apt-get update && apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# 7. 配置防火墙 (UFW)
apt-get install -y ufw
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# --- 输出总结 ---
clear
echo "========================================"
echo "          初始化完成！"
echo "========================================"
echo "用户名:     $USERNAME"
echo "初始密码:   $PASSWORD (建议保存以备万一)"
echo "SSH 端口:   $SSH_PORT"
echo "状态:       已启用公钥登录，已禁用密码登录"
echo "防火墙:     已放行 $SSH_PORT, 80, 443"
echo "========================================"
echo "请使用新终端尝试登录: ssh -p $SSH_PORT $USERNAME@服务器IP"
