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

# ================= SSH 安全修改（含 cloud-init 修复 + 本地 + 远程测试） =================
function safe_modify_ssh_port() {
    local NEWPORT=$1
    local SSHCFG="/etc/ssh/sshd_config"
    local BACKUP="/etc/ssh/sshd_config.bak_$NEWPORT"
    local REMOTE_IP=$(curl -s https://ipinfo.io/ip)

    echo "🔧 正 在 安 全 修 改 SSH 端 口 为 $NEWPORT..."
    sudo cp "$SSHCFG" "$BACKUP"

    # ==== 处理 cloud-init 覆盖 ====
    if ls /etc/ssh/sshd_config.d/*.conf >/dev/null 2>&1; then
        echo "🩹 正 在 处 理 cloud-init 配 置 覆 盖 ..."
        sudo sed -i 's/^\s*Port\s\+22/##Port 22/g' /etc/ssh/sshd_config.d/*.conf || true
    fi

    # 注释掉主配置中的所有 Port 行
    sudo sed -i 's/^\s*Port\s\+/##Port /' "$SSHCFG"

    # 添加新的端口配置
    echo "Port $NEWPORT" | sudo tee -a "$SSHCFG" >/dev/null

    # 防火墙放行
    sudo ufw allow "$NEWPORT"/tcp >/dev/null

    # 检查 SSH 配置语法
    if ! sudo sshd -t; then
        echo "❌ SSH 配 置 语 法 错 误 ！ 回 滚 ..."
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl restart ssh
        return 1
    fi

    # 重启 SSH
    sudo systemctl restart ssh
    sleep 1

    # ===== 本地监听检测 =====
    if ! sudo ss -tlnp | grep -E "(:$NEWPORT|:$NEWPORT\s)" >/dev/null; then
        echo "❌ SSH 未 在 本 地 监 听 端 口  $NEWPORT"
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl restart ssh
        return 1
    fi

    # ===== 公网 IP 测试 =====
    echo "🌐 正 在 测 试 公 网 连 通 性 ..."
    if ! nc -z -w3 $REMOTE_IP $NEWPORT >/dev/null 2>&1; then
        echo "❌ 公 网 无 法 连 接 $REMOTE_IP:$NEWPORT"
        echo "✔ 已 自 动 回 滚 到 旧 端 口"
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl restart ssh
        return 1
    fi

    sudo rm -f "$BACKUP"
    echo "✔ SSH 端 口 $NEWPORT 成 功 生 效"
    return 0
}
# ======================================================================

function init_vps() {
    echo "🚀 VPS 初 始 化 开 始 ..."

    read -p "请输入新用户名 [默认: $DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    while true; do
        read -p "请输入 SSH 端口 [默认: $DEFAULT_SSH_PORT]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
        if check_port "$SSH_PORT"; then
            echo "✅ SSH 端 口 $SSH_PORT 可 用"
            break
        else
            echo "❌ 端 口 $SSH_PORT 已 被 占 用"
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

    echo "🔒 开 始 安 全 修 改 SSH 端 口 ..."
    if safe_modify_ssh_port "$SSH_PORT"; then
        echo "✔ SSH 端 口 已 成 功 切 换 到 $SSH_PORT"
    else
        echo "⚠ SSH 端 口 修 改 失 败 ， 已 回 滚"
    fi

    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo "🎉 VPS 初 始 化 完 成 ！"
    echo "----------------------------------"
    echo "用 户 名: $USERNAME"
    echo "随 机 密 码: $RANDOM_PASS"
    echo "登 录 命 令:"
    echo "ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
    echo "----------------------------------"
}

# ==== 删除用户 ====
function delete_user() {
    read -p "请输入要删除的用户名 [默认: aleta]: " DEL_USER
    DEL_USER=${DEL_USER:-aleta}

    read -p "确 认 删 除 用 户 $DEL_USER 及 其 所 有 配 置 和 主 目 录？ [Y/n]: " confirm
    if [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
        sudo rm -f "/etc/sudoers.d/$DEL_USER"
        sudo userdel -rf "$DEL_USER" || true
        sudo rm -rf "/home/$DEL_USER"
        echo "✔ 用 户 $DEL_USER 已 删 除"
    else
        echo "已 取 消"
    fi
}

# ==== 主菜单 ====
function main_menu() {
    while true; do
        echo ""
        echo "===== VPS 管 理 菜 单 ====="
        echo "1. 初 始 化 VPS"
        echo "2. 删 除 用 户"
        echo "3. 退 出"
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
