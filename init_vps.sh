#!/bin/bash

# =================================================================
# 脚本名称: Ubuntu VPS 一键初始化脚本 (远程执行兼容版)
# 描述: 支持 curl | bash 远程调用，解决 SSH 端口修改无效及权限问题。
# =================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 权限检查与远程调用自提升修复 ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}检测到当前不是 root 用户，正在尝试提权...${NC}"
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}错误: 未找到 sudo 命令。请先手动执行 'su -' 切换到 root。${NC}"
        exit 1
    fi
    
    # 针对通过管道运行的特殊处理 (bash <(curl...))
    if [ -f "$0" ]; then
        # 如果是本地文件
        exec sudo -E bash "$0" "$@"
    else
        # 如果是通过管道运行的，重新通过 curl 下载并运行（或提醒用户）
        echo -e "${YELLOW}检测到远程执行模式，正在通过 sudo 重新获取并运行...${NC}"
        # 注意：这里假设了你的 GitHub 原始路径，如果不同请修改
        # 或者使用更通用的方案：将脚本内容存入临时文件执行
        TMP_SCRIPT=$(mktemp)
        curl -fsSL https://raw.githubusercontent.com/Alanniea/init/main/init_vps.sh > "$TMP_SCRIPT"
        sudo -E bash "$TMP_SCRIPT" "$@"
        rm -f "$TMP_SCRIPT"
        exit $?
    fi
fi

echo -e "${GREEN}=== Ubuntu VPS 一键初始化 (Root 模式) ===${NC}"

# 1. 交互输入
read -p "请输入新用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

echo -e "${YELLOW}请粘贴本地 ~/.ssh/id_rsa.pub 的内容:${NC}"
read -p "公钥: " PUBLIC_KEY

if [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}错误: 必须提供公钥。${NC}"
    exit 1
fi

RANDOM_PASS=$(openssl rand -base64 16)

# 2. 系统更新
echo -e "${YELLOW}正在更新系统 (DEBIAN_FRONTEND=noninteractive)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y

# 3. 创建用户与免密 Sudo
echo -e "${YELLOW}正在创建用户 $USERNAME...${NC}"
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"

mkdir -p /etc/sudoers.d
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 4. SSH 密钥部署
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 5. 解决 SSH 端口修改无效 (核心逻辑)
echo -e "${YELLOW}正在配置 SSH 端口并处理 systemd 兼容性...${NC}"

# 修改配置文件
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config

# 针对 Ubuntu 22.04+ ssh.socket 的关键修复
if systemctl is-active --quiet ssh.socket || [ -f /lib/systemd/system/ssh.socket ]; then
    echo -e "${YELLOW}检测到 ssh.socket，正在强制重定向端口...${NC}"
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOF > /etc/systemd/system/ssh.socket.d/listen.conf
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
    systemctl daemon-reload
    systemctl stop ssh.socket 2>/dev/null
    systemctl disable ssh.socket 2>/dev/null
fi

# 确保启动传统的 ssh 服务模式
systemctl restart ssh

# 6. 安装 Fail2ban
echo -e "${YELLOW}安装 Fail2ban...${NC}"
apt-get install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 1h
EOF
systemctl restart fail2ban

# 7. UFW 防火墙
echo -e "${YELLOW}配置 UFW 防火墙...${NC}"
apt-get install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 8. 汇总信息
IP_ADDR=$(curl -s ifconfig.me || echo "获取失败")
echo -e "\n${GREEN}================================================${NC}"
echo -e "${GREEN}          VPS 初始化成功！请保存登录信息          ${NC}"
echo -e "${GREEN}================================================${NC}"
echo -e "${YELLOW}用户:       ${NC} $USERNAME"
echo -e "${YELLOW}随机密码:   ${NC} $RANDOM_PASS"
echo -e "${YELLOW}SSH 端口:   ${NC} $SSH_PORT"
echo -e "${YELLOW}SSH 登录:   ${NC} ssh -p $SSH_PORT $USERNAME@$IP_ADDR"
echo -e "${GREEN}================================================${NC}"
echo -e "${RED}警告: 请务必先开新窗口测试能否登录，再断开当前连接！${NC}"

