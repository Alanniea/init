#!/bin/bash

# =================================================================
# 脚本名称: Ubuntu VPS 一键初始化脚本 (增强版)
# 描述: 自动设置用户、修复 SSH 端口修改失效问题、Sudo 免密、UFW、Fail2ban。
# =================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误: 请以 root 用户身份运行。${NC}"
  exit 1
fi

echo -e "${GREEN}=== Ubuntu VPS 一键初始化开始 ===${NC}"

# 1. 交互配置
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入自定义 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

echo -e "${YELLOW}请粘贴你的本地公钥 (SSH Public Key):${NC}"
read -p "公钥内容: " PUBLIC_KEY

if [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}错误: 必须提供公钥。${NC}"
    exit 1
fi

RANDOM_PASS=$(openssl rand -base64 16)

# 2. 更新系统
echo -e "${YELLOW}正在更新系统软件包...${NC}"
apt update && apt upgrade -y

# 3. 创建用户并设置 Sudo
echo -e "${YELLOW}正在创建用户: $USERNAME...${NC}"
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 4. 配置 SSH 公钥
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 5. 关键修复：处理 SSH 端口修改无效问题
echo -e "${YELLOW}正在强制修改 SSH 端口并处理 systemd socket 兼容性...${NC}"

# A. 修改传统的 sshd_config
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config

# B. 处理 Ubuntu 新版本中的 ssh.socket (如果存在)
if [ -d "/etc/systemd/system/ssh.socket.d" ] || [ -f "/lib/systemd/system/ssh.socket" ]; then
    echo -e "${YELLOW}检测到 systemd ssh.socket，正在应用覆盖配置...${NC}"
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOF > /etc/systemd/system/ssh.socket.d/listen.conf
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
    systemctl daemon-reload
fi

# 6. 安装 Fail2ban
echo -e "${YELLOW}正在安装并配置 Fail2ban...${NC}"
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

# 7. 配置 UFW
echo -e "${YELLOW}正在配置 UFW 防火墙...${NC}"
apt install -y ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 8. 重启服务
systemctl restart ssh
# 尝试停止并禁用 socket 以回归传统 sshd 服务模式（可选，但更稳定）
systemctl stop ssh.socket >/dev/null 2>&1
systemctl disable ssh.socket >/dev/null 2>&1
systemctl restart ssh

# 9. 报告
IP_ADDR=$(curl -s ifconfig.me)
echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}          VPS 初始化完成！请保存登录信息          ${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "${YELLOW}用户名:     ${NC} $USERNAME"
echo -e "${YELLOW}临时密码:   ${NC} $RANDOM_PASS"
echo -e "${YELLOW}SSH 端口:   ${NC} $SSH_PORT"
echo -e "${YELLOW}登录命令:   ${NC} ssh -p $SSH_PORT $USERNAME@$IP_ADDR"
echo -e "${GREEN}================================================${NC}"
echo -e "${RED}警告: 请务必保留当前窗口，新开一个窗口尝试登录成功后再关闭！${NC}"

