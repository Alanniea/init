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

# 检测 SSH 服务名称
function get_ssh_service_name() {
    if systemctl list-unit-files | grep -q "^sshd.service"; then
        echo "sshd"
    elif systemctl list-unit-files | grep -q "^ssh.service"; then
        echo "ssh"
    else
        echo "ssh"  # 默认
    fi
}

# ================= SSH 安全修改（含本地 + 远程测试） =================
function safe_modify_ssh_port() {
    local NEWPORT=$1
    local SSHCFG="/etc/ssh/sshd_config"
    local BACKUP="/etc/ssh/sshd_config.bak_$NEWPORT"
    local REMOTE_IP=$(curl -s https://ipinfo.io/ip)
    local SSH_SERVICE=$(get_ssh_service_name)

    echo "🔧 正在安全修改 SSH 端口为 $NEWPORT..."
    echo "📌 检测到 SSH 服务名称: $SSH_SERVICE"
    
    sudo cp "$SSHCFG" "$BACKUP"

    # 注释掉所有已有 Port
    sudo sed -i 's/^\s*Port\s\+/##Port /' "$SSHCFG"

    # 添加新端口（在文件开头添加，确保优先级）
    sudo sed -i "1iPort $NEWPORT" "$SSHCFG"

    # 防火墙放行新端口
    sudo ufw allow "$NEWPORT"/tcp >/dev/null
    echo "✔ 防火墙已放行端口 $NEWPORT"

    # 检查 SSH 配置语法
    echo "🔍 检查 SSH 配置语法..."
    if ! sudo sshd -t 2>&1; then
        echo "❌ SSH 配置语法错误！回滚..."
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl restart "$SSH_SERVICE"
        return 1
    fi
    echo "✔ SSH 配置语法正确"

    # 重启 SSH 服务
    echo "🔄 重启 SSH 服务 ($SSH_SERVICE)..."
    sudo systemctl restart "$SSH_SERVICE"
    
    # 等待 SSH 服务完全启动（最多等待 15 秒）
    echo "⏳ 等待 SSH 服务启动..."
    local retry=0
    local max_retries=15
    while [ $retry -lt $max_retries ]; do
        sleep 1
        retry=$((retry + 1))
        
        # 检查服务是否运行
        if ! sudo systemctl is-active --quiet "$SSH_SERVICE"; then
            echo "⚠ SSH 服务未运行，尝试 $retry/$max_retries"
            continue
        fi
        
        # 检查端口监听
        if sudo ss -tlnp | grep -E ":$NEWPORT\s" >/dev/null 2>&1; then
            echo "✔ SSH 已在本地监听端口 $NEWPORT"
            break
        fi
        
        if [ $retry -eq $max_retries ]; then
            echo "❌ SSH 没有在本地监听端口 $NEWPORT（超时）"
            echo "📋 当前监听的端口："
            sudo ss -tlnp | grep ssh
            echo "📋 SSH 服务状态："
            sudo systemctl status "$SSH_SERVICE" --no-pager -l
            echo "📋 最近的日志："
            sudo journalctl -u "$SSH_SERVICE" -n 20 --no-pager
            sudo mv "$BACKUP" "$SSHCFG"
            sudo systemctl restart "$SSH_SERVICE"
            return 1
        fi
        
        echo "⏳ 等待中... ($retry/$max_retries)"
    done

    # 远程公网 IP 测试连接
    if [ -n "$REMOTE_IP" ]; then
        echo "🌐 测试远程连接 $REMOTE_IP:$NEWPORT..."
        if ! timeout 5 bash -c "echo >/dev/tcp/$REMOTE_IP/$NEWPORT" 2>/dev/null; then
            echo "⚠ 无法通过公网 IP 连接 SSH，可能是："
            echo "  - 云服务商安全组未开放端口 $NEWPORT"
            echo "  - 网络防火墙限制"
            echo "  - NAT 配置问题"
            read -p "是否继续（本地测试已通过）？ [Y/n]: " confirm
            if [[ ! -z "$confirm" && ! "$confirm" =~ ^[Yy]$ ]]; then
                sudo mv "$BACKUP" "$SSHCFG"
                sudo systemctl restart "$SSH_SERVICE"
                echo "✔ 已自动回滚到旧端口"
                return 1
            fi
        else
            echo "✔ 远程连接测试成功"
        fi
    fi

    sudo rm -f "$BACKUP"
    echo "✔ SSH 新端口 $NEWPORT 成功启用"
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
    echo "请使用命令登录：ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
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
