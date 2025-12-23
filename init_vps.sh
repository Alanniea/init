#!/bin/bash

# =================================================================
# 脚本名称: Ubuntu VPS 一键初始化脚本 (高兼容权限版)
# 描述: 自动修复权限问题、解决 SSH 端口修改失效、配置安全登录。
# =================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 权限检查与自提升 (修复 fd 错误) ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}检测到当前不是 root 用户，尝试使用 sudo 提升权限...${NC}"
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}错误: 未找到 sudo 命令。请使用 'su -' 切换到 root 后再运行此脚本。${NC}"
        exit 1
    fi
    # 使用 sudo 重新运行脚本，显式传递脚本路径
    sudo -E bash "$BASH_SOURCE" "$@"
    exit $?
fi

echo -e "${GREEN}=== Ubuntu VPS 一键初始化开始 (Root 权限已就绪) ===${NC}"

# 1. 交互配置
# 确保在提权后依然能进行交互输入
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

# 2. 系统环境预设
export DEBIAN_FRONTEND=noninteractive

# 3. 更新系统
echo -e "${YELLOW}正在更新系统软件包...${NC}"
apt-get update && apt-get upgrade -y

# 4. 用户与 Sudo 配置
echo -e "${YELLOW}正在配置用户 $USERNAME 和免密 Sudo...${NC}"
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}用户 $USERNAME 已存在。${NC}"
else
    useradd -m -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"

mkdir -p /etc/sudoers.d
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 5. SSH 密钥部署
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. SSH 端口与服务修复 (核心修复)
echo -e "${YELLOW}正在修复 SSH 端口配置 ($SSH_PORT)...${NC}"

# 修改 sshd_config
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config

# 针对 Ubuntu 22.10+ 的 ssh.socket 修复
if systemctl is-active --quiet ssh.socket || [ -f /lib/systemd/system/ssh.socket ]; then
    echo -e "${YELLOW}检测到系统使用 ssh.socket，正在应用端口覆盖...${NC}"
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOF > /etc/systemd/system/ssh.socket.d/listen.conf
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
fi

systemctl restart ssh

# 7. Fail2ban 安装
echo -e "${YELLOW}正在部署 Fail2ban 防护...${NC}"
apt-get install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 1h
EOF
systemctl restart fail2ban

# 8. UFW 防火墙配置
echo -e "${YELLOW}正在开启 UFW 防火墙并放行端口...${NC}"
apt-get install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 9. 最终报告
IP_ADDR=$(curl -s ifconfig.me || echo "获取失败")
echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}          VPS 初始化成功！请务必记录以下信息          ${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "${YELLOW}管理用户:   ${NC} $USERNAME"
echo -e "${YELLOW}初始密码:   ${NC} $RANDOM_PASS"
echo -e "${YELLOW}SSH 端口:   ${NC} $SSH_PORT"
echo -e "${YELLOW}登录命令:   ${NC} ssh -p $SSH_PORT $USERNAME@$IP_ADDR"
echo -e "${YELLOW}Web 端口:   ${NC} 80, 443 已放行"
echo -e "${GREEN}================================================${NC}"
echo -e "${RED}警告: 请开启新终端测试登录，成功后再断开当前连接！${NC}"

