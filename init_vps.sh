#!/bin/bash

# =================================================================
# 脚本名称: Ubuntu VPS 一键初始化脚本
# 描述: 自动设置用户、SSH 端口、Sudo 免密、UFW 防火墙、Fail2ban 及 Web 端口。
# 作者: Gemini
# =================================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 检查是否为 root 用户运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请以 root 用户身份或使用 sudo 运行此脚本。${NC}"
  exit 1
fi

echo -e "${GREEN}=== Ubuntu VPS 一键初始化开始 ===${NC}"

# 1. 交互式配置变量
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入自定义 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

# 获取本地公钥
echo -e "${YELLOW}提示: 请在你的本地电脑运行 'cat ~/.ssh/id_rsa.pub' 获取公钥内容。${NC}"
echo -e "${YELLOW}请在此处粘贴你的本地公钥 (SSH Public Key):${NC}"
read -p "公钥内容: " PUBLIC_KEY

if [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}错误: 必须提供公钥才能配置安全的密钥登录。${NC}"
    exit 1
fi

# 2. 生成随机密码
RANDOM_PASS=$(openssl rand -base64 16)

# 3. 更新系统
echo -e "${YELLOW}正在更新系统软件包...${NC}"
apt update && apt upgrade -y

# 4. 创建用户并设置 Sudo
echo -e "${YELLOW}正在创建用户: $USERNAME...${NC}"
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"

# 启用免密 sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 5. 配置 SSH 目录和公钥
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. 安全化 SSH 配置
echo -e "${YELLOW}正在配置 SSH 服务 (端口: $SSH_PORT)...${NC}"
# 修改端口
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
# 禁用 root 登录
sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
# 禁用密码登录，仅允许密钥
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
# 确保启用公钥认证
sed -i "s/^#PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config

# 7. 安装并配置 Fail2ban
echo -e "${YELLOW}正在安装并配置 Fail2ban 防护...${NC}"
apt install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF
systemctl restart fail2ban

# 8. 配置 UFW 防火墙
echo -e "${YELLOW}正在配置 UFW 防火墙...${NC}"
apt install -y ufw
# 默认拒绝入站，允许出站
ufw default deny incoming
ufw default allow outgoing
# 放行 SSH、HTTP 和 HTTPS 端口
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
# 开启防火墙 (自动确认)
echo "y" | ufw enable

# 9. 重启 SSH 服务应用配置
systemctl restart ssh

# 10. 初始化汇总报告
IP_ADDR=$(curl -s ifconfig.me)
echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}          VPS 初始化完成！请妥善保存以下信息          ${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "${YELLOW}新用户名:   ${NC} $USERNAME"
echo -e "${YELLOW}随机密码:   ${NC} $RANDOM_PASS"
echo -e "${YELLOW}SSH 端口:   ${NC} $SSH_PORT"
echo -e "${YELLOW}登录命令:   ${NC} ssh -p $SSH_PORT $USERNAME@$IP_ADDR"
echo -e "${YELLOW}防火墙状态: ${NC} 已放行端口 $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)"
echo -e "${YELLOW}Sudo 权限:  ${NC} $USERNAME 已获得免密 Sudo 权限"
echo -e "${GREEN}================================================${NC}"
echo -e "${RED}重要提示: 在关闭当前窗口前，请务必新开一个终端测试是否能成功登录！${NC}"

