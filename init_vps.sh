#!/usr/bin/env bash
set -e

echo "========================================================"
echo " Ubuntu VPS 一键初始化脚本"
echo " 用户名: aleta"
echo " SSH 端口: 21357"
echo " 公钥路径: ~/.ssh/id_rsa.pub"
echo "========================================================"
echo ""
read -p "⚠️ 确认要继续执行初始化吗？(y/N): " yn
[ "$yn" != "y" ] && exit 1

USERNAME="aleta"
SSH_PORT=21357
PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"

# 检查公钥
if [ ! -f "$PUBKEY_PATH" ]; then
    echo "❌ 未找到公钥文件：$PUBKEY_PATH"
    exit 1
fi

# 生成随机密码
PASSWORD=$(openssl rand -base64 16)

echo "👉 开始初始化..."

# 创建用户
if ! id "$USERNAME" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$USERNAME"
fi

# 设置密码
echo "${USERNAME}:${PASSWORD}" | sudo chpasswd

# 免密 sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/${USERNAME}
chmod 440 /etc/sudoers.d/${USERNAME}

# 安装必要组件
apt update -y
apt install -y ufw fail2ban

# 配置 SSH 公钥
mkdir -p /home/${USERNAME}/.ssh
cat "$PUBKEY_PATH" > /home/${USERNAME}/.ssh/authorized_keys
chmod 700 /home/${USERNAME}/.ssh
chmod 600 /home/${USERNAME}/.ssh/authorized_keys
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh

# SSH 配置
SSH_CONFIG="/etc/ssh/sshd_config"

sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" $SSH_CONFIG
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" $SSH_CONFIG
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" $SSH_CONFIG

systemctl restart ssh

# 防火墙设置
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 启动 fail2ban
systemctl enable --now fail2ban

echo ""
echo "========================================================"
echo "🎉 初始化完成！以下是重要信息："
echo "👉 新用户: ${USERNAME}"
echo "👉 随机密码: ${PASSWORD}"
echo "👉 SSH 登录端口: ${SSH_PORT}"
echo "========================================================"
echo "请立即复制保存密码。"
