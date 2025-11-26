#!/bin/bash

# Ubuntu VPS 一键初始化脚本
# 用途：创建用户、配置 SSH、安装安全工具、配置防火墙

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置参数
USERNAME="aleta"
SSH_PORT="21357"
SSH_PUBKEY_PATH="$HOME/.ssh/id_rsa.pub"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以 root 权限运行"
   exit 1
fi

echo "========================================="
echo "  Ubuntu VPS 初始化脚本"
echo "========================================="
echo ""
log_info "用户名: $USERNAME"
log_info "SSH 端口: $SSH_PORT"
log_info "公钥路径: $SSH_PUBKEY_PATH"
echo ""
read -p "按 Enter 继续，或 Ctrl+C 取消..." 

# 1. 更新系统
log_info "更新系统软件包..."
apt update && apt upgrade -y

# 2. 创建用户
log_info "创建用户 $USERNAME..."
if id "$USERNAME" &>/dev/null; then
    log_warn "用户 $USERNAME 已存在，跳过创建"
else
    # 生成随机密码
    PASSWORD=$(openssl rand -base64 24)
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    log_info "用户 $USERNAME 已创建"
    echo ""
    echo "========================================="
    echo -e "${GREEN}用户密码（请妥善保存）:${NC}"
    echo -e "${YELLOW}$PASSWORD${NC}"
    echo "========================================="
    echo ""
fi

# 3. 配置 sudo 免密
log_info "配置 sudo 免密..."
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME

# 4. 配置 SSH 密钥
log_info "配置 SSH 密钥..."
USER_HOME="/home/$USERNAME"
SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"

if [[ -f "$SSH_PUBKEY_PATH" ]]; then
    cat "$SSH_PUBKEY_PATH" > "$AUTHORIZED_KEYS"
    log_info "已导入公钥"
else
    log_error "公钥文件不存在: $SSH_PUBKEY_PATH"
    read -p "请粘贴公钥内容（按 Enter 结束）: " PUBKEY
    echo "$PUBKEY" > "$AUTHORIZED_KEYS"
fi

chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# 5. 配置 SSH
log_info "配置 SSH 服务..."
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%F)"

# 修改 SSH 配置
sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSH_CONFIG"
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSH_CONFIG"
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSH_CONFIG"

# 确保配置存在
grep -q "^Port $SSH_PORT" "$SSH_CONFIG" || echo "Port $SSH_PORT" >> "$SSH_CONFIG"
grep -q "^PermitRootLogin no" "$SSH_CONFIG" || echo "PermitRootLogin no" >> "$SSH_CONFIG"
grep -q "^PasswordAuthentication no" "$SSH_CONFIG" || echo "PasswordAuthentication no" >> "$SSH_CONFIG"
grep -q "^PubkeyAuthentication yes" "$SSH_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSH_CONFIG"

log_info "SSH 配置已更新"

# 6. 安装 fail2ban
log_info "安装 fail2ban..."
apt install -y fail2ban

# 配置 fail2ban
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

systemctl enable fail2ban
systemctl start fail2ban
log_info "fail2ban 已安装并启动"

# 7. 配置防火墙 (UFW)
log_info "配置防火墙..."
apt install -y ufw

# 重置防火墙规则
ufw --force reset

# 允许必要端口
ufw allow $SSH_PORT/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# 设置默认策略
ufw default deny incoming
ufw default allow outgoing

# 启用防火墙
ufw --force enable

log_info "防火墙已配置并启用"

# 8. 重启 SSH 服务
log_info "重启 SSH 服务..."
systemctl restart sshd

# 完成提示
echo ""
echo "========================================="
log_info "初始化完成！"
echo "========================================="
echo ""
echo "重要信息："
echo "  - 用户名: $USERNAME"
echo "  - SSH 端口: $SSH_PORT"
echo "  - 已禁用 root 登录和密码认证"
echo "  - 已启用 fail2ban 保护"
echo "  - 已开放端口: $SSH_PORT, 80, 443"
echo ""
log_warn "请在关闭当前 SSH 会话前，先用新配置测试登录："
echo -e "${YELLOW}  ssh -p $SSH_PORT $USERNAME@YOUR_SERVER_IP${NC}"
echo ""
echo "防火墙状态："
ufw status numbered
echo ""
log_info "脚本执行完毕！"
