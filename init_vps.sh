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

# =============== SSH 端口安全修改（含自动回滚） ==================
function safe_modify_ssh_port() {
    local NEWPORT=$1
    local SSHCFG="/etc/ssh/sshd_config"
    local BACKUP="/etc/ssh/sshd_config.bak_$NEWPORT"

    echo "🔧 正在安全修改 SSH 端口为 $NEWPORT..."

    # 备份
    sudo cp "$SSHCFG" "$BACKUP"

    # 注释所有 Port 行
    sudo sed -i 's/^\s*Port\s\+/##Port /' "$SSHCFG"

    # 写入新的端口
    echo "Port $NEWPORT" | sudo tee -a "$SSHCFG" >/dev/null

    # 检查 SSH 配置是否正确
    if ! sudo sshd -t; then
        echo "❌ SSH 配置语法错误！"
        sudo mv "$BACKUP" "$SSHCFG"
        echo "✔ 已自动恢复原配置"
        return 1
    fi

    # 重启 SSH
    sudo systemctl restart ssh

    sleep 1

    # 检查本机是否在监听该端口
    if ! ss -tln | grep -q ":$NEWPORT "; then
        echo "❌ SSH 没有在监听端口 $NEWPORT"
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl restart ssh
        echo "✔ 已自动回滚到旧端口"
        return 1
    fi

    # 检查防火墙是否放行
    sudo ufw allow "$NEWPORT"/tcp >/dev/null

    sleep 1

    # 尝试连接新端口（本地测试）
    if ! nc -z 127.0.0.1 "$NEWPORT" >/dev/null 2>&1; then
        echo "❌ 无法连接到本地 SSH 新端口 $NEWPORT，可能会锁死"
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl restart ssh
        echo "✔ 已自动回滚到旧端口"
        return 1
    fi

    echo "🎉 SSH 新端口 $NEWPORT 测试成功！"
    echo "✔ 安全启用该端口"

    # 删除备份
    sudo rm -f "$BACKUP"
    return 0
}
# ===============================================================

function init_vps() {
    echo "🚀 VPS 初始化开始..."

    read -p "请输入新用户名 [默认: $DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    while true; do
        read -p "请输入 SSH 端口 [默认: $DEFAULT_SSH_PORT]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
        if check_port "$SSH_PORT"; then
            echo "✅ SSH 端口 $SSH_PORT 可用"
            break
        else
            echo "❌ 端口 $SSH_PORT 已被占用"
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
        echo "✔ SSH 端口已安全切换为 $SSH_PORT"
    else
        echo "⚠ SSH 端口修改失败，已回滚，使用原端口继续"
    fi

    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo "🎉 VPS 初始化完成！"
    echo "用户名: $USERNAME"
    echo "随机密码: $RANDOM_PASS"
}

# ==== 删除用户 ====
function delete_user() {
    read -p "请输入要删除的用户名 [默认: aleta]: " DEL_USER
    DEL_USER=${DEL_USER:-aleta}

    read -p "确认删除用户 $DEL_USER 及其所有配置？ [Y/n]: " confirm
    if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
        sudo rm -f "/etc/sudoers.d/$DEL_USER"
        sudo userdel -rf "$DEL_USER" || true
        sudo rm -rf "/home/$DEL_USER"
        echo "✔ 用户 $DEL_USER 已删除"
    else
        echo "已取消"
    fi
}

# ==== 主菜单 ====
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
