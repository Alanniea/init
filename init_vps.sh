#!/usr/bin/env bash
set -euo pipefail

# ===== 默认参数 =====
DEFAULT_USERNAME="aleta"
DEFAULT_SSH_PORT=21357
DEFAULT_LOCAL_SSH_KEY="$HOME/.ssh/id_rsa.pub"
# ====================

# 检查端口是否被监听（正确且兼容所有 Debian/Ubuntu）
check_port() {
    local port=$1
    # 只检测监听状态，避免误判
    if ss -ltn | awk '{print $4}' | grep -q ":$port\$"; then
        return 1  # 被占用
    else
        return 0  # 可用
    fi
}

init_vps() {
    echo "🚀 VPS 初始化开始..."

    # 用户名
    read -p "请输入新用户名 [默认: $DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    # 端口（带占用检测）
    while true; do
        read -p "请输入 SSH 端口 [默认: $DEFAULT_SSH_PORT]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
        
        if [[ ! $SSH_PORT =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -le 0 ] || [ "$SSH_PORT" -gt 65535 ]; then
            echo "❌ 端口必须是 1-65535 的数字，请重试"
            continue
        fi

        if check_port "$SSH_PORT"; then
            echo "✅ SSH 端口 $SSH_PORT 可用"
            break
        else
            echo "❌ 端口 $SSH_PORT 已被占用，请输入其他端口"
        fi
    done

    # 公钥
    read -p "请输入本地 SSH 公钥路径 [默认: $DEFAULT_LOCAL_SSH_KEY]: " LOCAL_SSH_KEY
    LOCAL_SSH_KEY=${LOCAL_SSH_KEY:-$DEFAULT_LOCAL_SSH_KEY}

    echo "-> 更新系统..."
    sudo apt update && sudo apt upgrade -y

    echo "-> 创建用户 $USERNAME ..."
    if id "$USERNAME" >/dev/null 2>&1; then
        echo "⚠ 用户已存在，跳过创建"
    else
        sudo adduser --disabled-password --gecos "" "$USERNAME"
    fi

    RANDOM_PASS=$(openssl rand -base64 12)
    echo "$USERNAME:$RANDOM_PASS" | sudo chpasswd

    echo "-> 添加到 sudo 并设置免密 sudo ..."
    sudo usermod -aG sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$USERNAME" >/dev/null
    sudo chmod 440 "/etc/sudoers.d/$USERNAME"

    echo "-> 配置 SSH 公钥 ..."
    if [ -f "$LOCAL_SSH_KEY" ]; then
        sudo mkdir -p "/home/$USERNAME/.ssh"
        sudo cp "$LOCAL_SSH_KEY" "/home/$USERNAME/.ssh/authorized_keys"
        sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
        sudo chmod 700 "/home/$USERNAME/.ssh"
        sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
        echo "✅ 公钥已复制"
    else
        echo "⚠ 未找到公钥：$LOCAL_SSH_KEY （你可以之后手动上传）"
    fi

    echo "-> 修改 SSH 配置..."
    SSHD_CONF="/etc/ssh/sshd_config"
    sudo cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"

    sudo sed -i 's/^[[:space:]]*Port.*/#Port/' "$SSHD_CONF"
    sudo sed -i 's/^[[:space:]]*PermitRootLogin.*/#PermitRootLogin/' "$SSHD_CONF"

    echo "Port $SSH_PORT" | sudo tee -a "$SSHD_CONF" >/dev/null
    echo "PermitRootLogin yes" | sudo tee -a "$SSHD_CONF" >/dev/null

    sudo systemctl restart ssh

    echo "-> 安装 ufw / fail2ban ..."
    sudo apt install -y ufw fail2ban

    sudo ufw allow "$SSH_PORT"/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable

    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo ""
    echo "🎉 VPS 初始化完成！"
    echo "========================"
    echo "用户名: $USERNAME"
    echo "密码: $RANDOM_PASS"
    echo "SSH 端口: $SSH_PORT"
    echo "登录命令:"
    echo "ssh -p $SSH_PORT $USERNAME@你的IP"
    echo "========================"
    echo ""
}

delete_user() {
    read -p "请输入要删除的用户名 [默认: aleta]: " DEL_USER
    DEL_USER=${DEL_USER:-aleta}

    echo
    read -p "确认删除用户 $DEL_USER 及其所有配置？ [Y/n]: " confirm
    confirm=${confirm:-y}

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "🧹 正在删除..."

        sudo rm -f "/etc/sudoers.d/$DEL_USER"
        sudo userdel -rf "$DEL_USER" 2>/dev/null || true
        sudo rm -rf "/home/$DEL_USER" 2>/dev/null || true

        echo "✅ 用户 $DEL_USER 已彻底删除"
    else
        echo "❎ 已取消"
    fi
}

main_menu() {
    while true; do
        echo ""
        echo "===== VPS 管理菜单 ====="
        echo "1) 初始化 VPS"
        echo "2) 删除用户"
        echo "3) 退出"
        read -p "请选择操作 [1-3]: " choice
        
        case "$choice" in
            1) init_vps ;;
            2) delete_user ;;
            3) exit 0 ;;
            *) echo "无效输入，请重试" ;;
        esac
    done
}

main_menu
