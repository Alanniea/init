#!/bin/bash

# Ubuntu VPS 一键初始化脚本
# 使用方法: sudo bash init.sh

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   Ubuntu VPS 初始化脚本${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 sudo 运行此脚本${NC}"
    exit 1
fi

# 配置变量
USERNAME="aleta"
SSH_PORT="21357"
SSH_PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"

# 确认配置
echo -e "${YELLOW}配置信息:${NC}"
echo "  用户名: $USERNAME"
echo "  SSH 端口: $SSH_PORT"
echo "  公钥路径: $SSH_PUBKEY_PATH"
echo ""
read -p "确认配置无误? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}已取消${NC}"
    exit 1
fi

# 检查公钥文件
if [ ! -f "$SSH_PUBKEY_PATH" ]; then
    echo -e "${RED}错误: 公钥文件不存在: $SSH_PUBKEY_PATH${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}[1/8] 更新系统...${NC}"
apt update && apt upgrade -y

echo ""
echo -e "${GREEN}[2/8] 创建用户 $USERNAME...${NC}"
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}用户已存在，跳过创建${NC}"
else
    # 生成随机密码 (16字符，包含字母数字和特殊字符)
    USER_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-16)
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo -e "${GREEN}用户创建成功！${NC}"
    echo -e "${YELLOW}用户名: $USERNAME${NC}"
    echo -e "${YELLOW}密码: $USER_PASSWORD${NC}"
    echo -e "${RED}请妥善保存此密码！${NC}"
    echo ""
fi

echo ""
echo -e "${GREEN}[3/8] 配置 SSH 密钥...${NC}"
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
cp "$SSH_PUBKEY_PATH" /home/$USERNAME/.ssh/authorized_keys
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
echo -e "${GREEN}SSH 密钥配置完成${NC}"

echo ""
echo -e "${GREEN}[4/8] 配置 sudo 权限...${NC}"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
chmod 0440 /etc/sudoers.d/$USERNAME
echo -e "${GREEN}免密 sudo 已启用${NC}"

echo ""
echo -e "${GREEN}[5/8] 配置 SSH 服务...${NC}"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config

# 确保配置生效
if ! grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

systemctl restart sshd
echo -e "${GREEN}SSH 端口已更改为 $SSH_PORT${NC}"

echo ""
echo -e "${GREEN}[6/8] 安装并配置 fail2ban...${NC}"
apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# 创建 fail2ban SSH jail 配置
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl restart fail2ban
echo -e "${GREEN}fail2ban 已安装并配置${NC}"

echo ""
echo -e "${GREEN}[7/8] 配置防火墙 (UFW)...${NC}"
apt install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
echo -e "${GREEN}防火墙已配置 (SSH: $SSH_PORT, HTTP: 80, HTTPS: 443)${NC}"

echo ""
echo -e "${GREEN}[8/8] 优化系统设置...${NC}"
# 禁用 root SSH 登录提示
touch /root/.hushlogin

# 设置时区为 UTC (可根据需要修改)
timedatectl set-timezone UTC

echo -e "${GREEN}系统优化完成${NC}"

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   初始化完成！${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo -e "${YELLOW}重要信息:${NC}"
echo "  用户名: $USERNAME"
if [ -n "$USER_PASSWORD" ]; then
    echo -e "  密码: ${RED}$USER_PASSWORD${NC}"
fi
echo "  SSH 端口: $SSH_PORT"
echo "  SSH 密钥: 已配置"
echo "  Sudo: 免密启用"
echo ""
echo -e "${YELLOW}下一步操作:${NC}"
echo "  1. 请在新终端测试 SSH 连接："
echo -e "     ${GREEN}ssh -p $SSH_PORT $USERNAME@<服务器IP>${NC}"
echo "  2. 确认能够正常登录后，可以关闭当前会话"
echo "  3. 防火墙状态: $(ufw status | grep Status)"
echo ""
echo -e "${RED}警告: 请务必在断开当前连接前测试新的 SSH 配置！${NC}"
echo ""
