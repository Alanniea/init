#!/usr/bin/env bash
set -e

# ==== 默认参数 ====
DEFAULT_USERNAME="aleta"
DEFAULT_SSH_PORT=21357
DEFAULT_LOCAL_SSH_KEY="$HOME/.ssh/id_rsa.pub"
# ==================

function check_port() {
    local port=$1
    if sudo lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

# ============== 安全修改 SSH 端口（通过 99-custom-port.conf，含本地+公网检测） ==============
function safe_modify_ssh_port() {
    local NEWPORT=$1
    local CUSTOM="/etc/ssh/sshd_config.d/99-custom-port.conf"
    local BACKUP="${CUSTOM}.bak"
    local REMOTE_IP=""
    # 尝试获取公网 IP（网络不可用时不影响本地检测）
    if command -v curl >/dev/null 2>&1; then
        REMOTE_IP=$(curl -s https://ipinfo.io/ip 2>/dev/null || echo "")
    fi

    echo "🔧 使用 $CUSTOM 设置 SSH 端口为 $NEWPORT（优先级最高）..."

    # 安装必要工具（nc 用于测试）
    if ! command -v nc >/dev/null 2>&1; then
        sudo apt-get update -y >/dev/null 2>&1 || true
        sudo apt-get install -y netcat-openbsd >/dev/null 2>&1 || true
    fi

    # 备份已有自定义文件（如果有）
    if [ -f "$CUSTOM" ]; then
        sudo cp "$CUSTOM" "$BACKUP"
    fi

    # 写入/覆盖自定义 conf（确保优先级高于 cloud-init）
    echo "Port $NEWPORT" | sudo tee "$CUSTOM" >/dev/null
    sudo chmod 644 "$CUSTOM"

    # 优先放行防火墙新端口（避免被 ufw 拦截）
    sudo ufw allow "$NEWPORT"/tcp >/dev/null 2>&1 || true

    # 语法检查
    if ! sudo sshd -t; then
        echo "❌ sshd 配置语法错误，恢复自定义文件并退出"
        if [ -f "$BACKUP" ]; then sudo mv "$BACKUP" "$CUSTOM"; else sudo rm -f "$CUSTOM"; fi
        sudo systemctl restart ssh
        return 1
    fi

    # 重启 ssh 并短等
    sudo systemctl restart ssh
    sleep 1

    # 检测监听（兼容 IPv4/IPv6）
    if ! sudo ss -tlnp | grep -E "(:$NEWPORT\b|:$NEWPORT\s)" >/dev/null; then
        echo "❌ sshd 未监听端口 $NEWPORT，恢复自定义文件并退出"
        if [ -f "$BACKUP" ]; then sudo mv "$BACKUP" "$CUSTOM"; else sudo rm -f "$CUSTOM"; fi
        sudo systemctl restart ssh
        return 1
    fi

    # 如果能拿到公网 IP，则测试公网连通性；若失败则回滚
    if [ -n "$REMOTE_IP" ]; then
        echo "🌐 测试公网连接 $REMOTE_IP:$NEWPORT ..."
        if ! nc -z -w3 "$REMOTE_IP" "$NEWPORT" >/dev/null 2>&1; then
            echo "❌ 公网连接测试失败，恢复自定义文件并退出"
            if [ -f "$BACKUP" ]; then sudo mv "$BACKUP" "$CUSTOM"; else sudo rm -f "$CUSTOM"; fi
            sudo systemctl restart ssh
            return 1
        fi
    fi

    # 成功：删除备份（如有）
    sudo rm -f "$BACKUP" 2>/dev/null || true
    echo "✔ SSH 端口 $NEWPORT 已成功启用（通过 $CUSTOM）"
    return 0
}
# =======================================================================================

function init_vps() {
    echo "🚀 开始 VPS 初始化..."

    read -p "请输入新用户名 [默认: $DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    while true; do
        read -p "请输入 SSH 端口 [默认: $DEFAULT_SSH_PORT]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
        if check_port "$SSH_PORT"; then
            echo "✅ 端口 $SSH_PORT 可用"
            break
        else
            echo "❌ 端口 $SSH_PORT 已被占用，请换一个"
        fi
    done

    read -p "请输入本地 SSH 公钥路径 [默认: $DEFAULT_LOCAL_SSH_KEY]: " LOCAL_SSH_KEY
    LOCAL_SSH_KEY=${LOCAL_SSH_KEY:-$DEFAULT_LOCAL_SSH_KEY}

    sudo apt update && sudo apt upgrade -y

    sudo adduser --disabled-password --gecos "" $USERNAME
    RANDOM_PASS=$(openssl rand -base64 12)
    echo "$USERNAME:$RANDOM_PASS" | sudo chpasswd

    sudo usermod -aG sudo $USERNAME
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USERNAME >/dev/null

    sudo mkdir -p /home/$USERNAME/.ssh
    sudo cp "$LOCAL_SSH_KEY" /home/$USERNAME/.ssh/authorized_keys
    sudo chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    sudo chmod 700 /home/$USERNAME/.ssh
    sudo chmod 600 /home/$USERNAME/.ssh/authorized_keys

    sudo apt install -y ufw fail2ban
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable

    echo "🔒 开始安全修改 SSH 端口..."
    if safe_modify_ssh_port "$SSH_PORT"; then
        echo "✔ SSH 端口已切换为 $SSH_PORT"
    else
        echo "⚠ SSH 端口修改失败，已回滚为原端口"
    fi

    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo "🎉 初始化完成"
    echo "用户名: $USERNAME"
    echo "随机密码: $RANDOM_PASS"
    echo "登录命令: ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
}

function delete_user() {
    read -p "请输入要删除的用户名 [默认: aleta]: " DEL_USER
    DEL_USER=${DEL_USER:-aleta}

    read -p "确认删除用户 $DEL_USER 及其所有配置和主目录？ [Y/n]: " confirm
    if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
        sudo rm -f "/etc/sudoers.d/$DEL_USER"
        sudo userdel -rf "$DEL_USER" || true
        sudo rm -rf "/home/$DEL_USER"
        echo "✔ 用户 $DEL_USER 已删除"
    else
        echo "已取消"
    fi
}

function main_menu() {
    while true; do
        echo ""
        echo "===== VPS 管理菜单 ====="
        echo "1. 初始化 VPS"
        echo "2. 删除用户"
        echo "3. 退出"
        read -p "请选择操作 [1-3]: " choice
        case $choice in
            1) init_vps ;;
            2) delete_user ;;
            3) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
}

main_menu
