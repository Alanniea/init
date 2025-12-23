#!/bin/bash

# =================================================================
# 脚本名称: Ubuntu VPS 一键初始化脚本 (权限增强版)
# 描述: 自动修复权限问题、解决 SSH 端口修改失效、配置安全登录。
# =================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 权限检查与自提升 ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}检测到当前不是 root 用户，尝试使用 sudo 提升权限...${NC}"
    # 检查是否有 sudo 命令
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}错误: 未找到 sudo 命令，且当前不是 root 用户。请执行 'su -' 切换到 root 后再运行。${NC}"
        exit 1
    fi
    # 尝试使用 sudo 重新运行脚本
    exec sudo bash "$0" "$@"
    exit $?
fi

echo -e "${GREEN}=== Ubuntu VPS 一键初始化开始 (已获得 root 权限) ===${NC}"

# 1. 交互配置
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入自定义 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

echo -e "${YELLOW}提示: 请在本地运行 'cat ~/.ssh/id_rsa.pub' 并复制内容。${NC}"
echo -e "${YELLOW}请在此处粘贴你的本地公钥 (SSH Public Key):${NC}"
read -p "公钥内容: " PUBLIC_KEY

if [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}错误: 必须提供公钥以确保安全登录。${NC}"
    exit 1
fi

RANDOM_PASS=$(openssl rand -base64 16)

# 2. 更新系统
echo -e "${YELLOW}正在更新系统软件包 (可能需要几分钟)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y

# 3. 创建用户并设置免密 Sudo
echo -e "${YELLOW}正在创建并配置用户: $USERNAME...${NC}"
# 如果用户已存在，则跳过创建
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}用户 $USERNAME 已存在，正在更新配置...${NC}"
else
    useradd -m -s /bin/bash "$USERNAME"
fi

echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"

# 确保 sudoers 目录存在并写入免密配置
mkdir -p /etc/sudoers.d
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 4. 配置 SSH 公钥登录
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 5. 解决 SSH 端口修改无效问题 (处理 ssh.socket)
echo -e "${YELLOW}正在配置 SSH 服务并修复端口监听...${NC}"

# A. 修改 sshd_config
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config

# B. 核心修复：处理 Ubuntu 的 systemd ssh.socket
# 创建覆盖配置，让 socket 监听新端口
mkdir -p /etc/systemd/system/ssh.socket.d
cat <<EOF > /etc/systemd/system/ssh.socket.d/listen.conf
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF

systemctl daemon-reload

# 6. 安装 Fail2ban
echo -e "${YELLOW}正在安装并启动 Fail2ban 防护...${NC}"
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
systemctl enable fail2ban
systemctl restart fail2ban

# 7. 配置 UFW 防火墙
echo -e "${YELLOW}正在配置 UFW 防火墙策略...${NC}"
apt install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 8. 重启 SSH
echo -e "${YELLOW}正在重启 SSH 服务...${NC}"
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart ssh.service

# 9. 汇总报告
IP_ADDR=$(curl -s ifconfig.me || echo "无法获取外网IP")
echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}          VPS 初始化完成！请保存以下信息          ${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "${YELLOW}本地公钥:   ${NC} 已成功安装"
echo -e "${YELLOW}管理用户:   ${NC} $USERNAME"
echo -e "${YELLOW}初始密码:   ${NC} $RANDOM_PASS (用于某些需要输入密码的场景)"
echo -e "${YELLOW}SSH 端口:   ${NC} $SSH_PORT"
echo -e "${YELLOW}登录命令:   ${NC} ssh -p $SSH_PORT $USERNAME@$IP_ADDR"
echo -e "${YELLOW}免密 Sudo:  ${NC} 已启用 (sudo 不需要密码)"
echo -e "${GREEN}================================================${NC}"
echo -e "${RED}重要提示: 请保留此窗口，打开新窗口尝试登录。${NC}"
echo -e "${RED}如果新窗口登录失败，请在当前窗口执行 'ufw disable' 紧急关闭防火墙检查。${NC}"

