#!/usr/bin/env bash
set -euo pipefail

# ===== 默认参数（可在交互时修改） =====
DEFAULT_USERNAME="aleta"
DEFAULT_SSH_PORT=21357
DEFAULT_LOCAL_SSH_KEY="$HOME/.ssh/id_rsa.pub"
# =======================================

# 检查端口是否被监听（使用 ss，系统自带）
check_port() {
    local port=$1
    if ss -ltn "( sport = :$port )" >/dev/null 2>&1; then
        return 1  # 被占用
    else
        return 0  # 可用
    fi
}

init_vps() {
    echo "🚀 VPS 初始化开始..."

    # 交互获取参数
    read -p "请输入新用户名 [默认: $DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    while true; do
        read -p "请输入 SSH 端口 [默认: $DEFAULT_SSH_PORT]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
        if [[ ! $SSH_PORT =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -le 0 ] || [ "$SSH_PORT" -gt 65535 ]; then
            echo "❌ 端口必须是 1-65535 的数字，请重新输入"
            continue
        fi
        if check_port "$SSH_PORT"; then
            echo "✅ SSH 端口 $SSH_PORT 可用"
            break
        else
            echo "❌ 端口 $SSH_PORT 已被占用，请输入其他端口"
        fi
    done

    read -p "请输入本地 SSH 公钥路径 [默认: $DEFAULT_LOCAL_SSH_KEY]: " LOCAL_SSH_KEY
    LOCAL_SSH_KEY=${LOCAL_SSH_KEY:-$DEFAULT_LOCAL_SSH_KEY}

    echo "-> 更新系统包..."
    sudo apt update && sudo apt upgrade -y

    echo "-> 创建用户 $USERNAME ..."
    # 如果用户已存在则不重复创建
    if id "$USERNAME" >/dev/null 2>&1; then
        echo "⚠ 用户 $USERNAME 已存在，跳过创建"
    else
        sudo adduser --disabled-password --gecos "" "$USERNAME"
    fi

    RANDOM_PASS=$(openssl rand -base64 12)
    echo "$USERNAME:$RANDOM_PASS" | sudo chpasswd

    echo "-> 将 $USERNAME 加入 sudo 并设置免密 sudo ..."
    sudo usermod -aG sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$USERNAME" >/dev/null
    sudo chmod 440 "/etc/sudoers.d/$USERNAME"

    echo "-> 配置 SSH 公钥（如果提供的公钥存在）..."
    if [ -f "$LOCAL_SSH_KEY" ]; then
        sudo mkdir -p "/home/$USERNAME/.ssh"
        sudo cp "$LOCAL_SSH_KEY" "/home/$USERNAME/.ssh/authorized_keys"
        sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
        sudo chmod 700 "/home/$USERNAME/.ssh"
        sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
        echo "✅ 公钥已复制到 /home/$USERNAME/.ssh/authorized_keys"
    else
        echo "⚠ 未找到公钥文件：$LOCAL_SSH_KEY 。跳过复制（你仍可手动上传公钥）。"
    fi

    echo "-> 修改 SSH 配置：设置端口 $SSH_PORT 并允许 root 登录..."
    SSHD_CONF="/etc/ssh/sshd_config"
    # 备份
    sudo cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"
    # 注释掉已有的 Port 行并追加新的
    sudo sed -i 's/^[[:space:]]*Port[[:space:]]\+/ #Port /I' "$SSHD_CONF" || true
    # 注释掉已有的 PermitRootLogin 行并追加新的
    sudo sed -i 's/^[[:space:]]*PermitRootLogin[[:space:]]\+/ #PermitRootLogin /I' "$SSHD_CONF" || true
    echo "Port $SSH_PORT" | sudo tee -a "$SSHD_CONF" >/dev/null
    echo "PermitRootLogin yes" | sudo tee -a "$SSHD_CONF" >/dev/null

    echo "-> 重启 SSH 服务以应用配置..."
    sudo systemctl restart ssh

    echo "-> 安装并配置 ufw 和 fail2ban..."
    sudo apt install -y ufw fail2ban
    sudo ufw allow "$SSH_PORT"/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo ""
    echo "✅ VPS 初始化完成！"
    echo "用户名: $USERNAME"
    echo "随机密码: $RANDOM_PASS"
    echo "登录示例: ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
    echo "（注意：如果你未复制公钥，请使用密码登录后上传公钥并禁用密码登录）"
    echo ""
}

delete_user() {
    read -p "请输入要删除的用户名 [默认: aleta]: " DEL_USER
    DEL_USER=${DEL_USER:-aleta}

    if [ -z "$DEL_USER" ]; then
        echo "用户名不能为空"
        return
    fi

    echo
    # 确认提示默认 y
    read -p "确 认 删 除 用 户  $DEL_USER 及 其 所 有 配 置 和 主 目 录 ？ [Y/n]: " confirm
    confirm=${confirm:-y}

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "🧹 正在删除用户 $DEL_USER ..."
        # 删除 sudoers 配置
        SUDOERS_FILE="/etc/sudoers.d/$DEL_USER"
        if sudo test -f "$SUDOERS_FILE"; then
            sudo rm -f "$SUDOERS_FILE"
            echo "✅ 删除 sudoers 配置 $SUDOERS_FILE"
        fi

        # 删除用户及主目录
        if id "$DEL_USER" >/dev/null 2>&1; then
            sudo userdel -rf "$DEL_USER" 2>/dev/null || true
        fi
        sudo rm -rf "/home/$DEL_USER" 2>/dev/null || true

        echo "✅ 用户 $DEL_USER 已被完全删除（包含 sudoers 配置与主目录）"
    else
        echo "❎ 已取消删除。"
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
            3) echo "退出脚本"; exit 0 ;;
            *) echo "无效选项，请重新输入 (1-3)" ;;
        esac
    done
}

# 入口
main_menu
