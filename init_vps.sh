#!/bin/bash

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "请以 root 用户运行此脚本"
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
    echo "错误：必须提供 SSH 公钥才能继续。"
    exit 1
fi

# 2. 生成随机密码
PASSWORD=$(openssl rand -base64 12)

# 3. 更新系统
apt update && apt upgrade -y

# 4. 创建用户并设置权限
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME"

# 5. 配置免密 sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"

# 6. 配置 SSH 密钥登录
USER_HOME=$(eval echo "~$USERNAME")
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 7. 修改 SSH 配置
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart ssh

# 8. 安装 fail2ban
apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# 9. 配置 UFW 防火墙
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 10. 输出结果
clear
echo "========================================"
echo "          初始化完成！                  "
echo "========================================"
echo "用户名: $USERNAME"
echo "初始密码: $PASSWORD (建议保存，虽然已开启免密sudo)"
echo "SSH 端口: $SSH_PORT"
echo "防火墙已放行: $SSH_PORT, 80, 443"
echo "----------------------------------------"
echo "请使用以下命令尝试登录:"
echo "ssh -p $SSH_PORT $USERNAME@$(curl -s ifconfig.me)"
echo "========================================"
EOF

chmod +x init.sh
./init.sh
