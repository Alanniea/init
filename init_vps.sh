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
        echo "ssh"
    fi
}

# ================= SSH 安全修改（含本地 + 远程测试） =================
function safe_modify_ssh_port() {
    local NEWPORT=$1
    local SSHCFG="/etc/ssh/sshd_config"
    local BACKUP="/etc/ssh/sshd_config.bak_$NEWPORT"
    local REMOTE_IP=$(curl -s https://ipinfo.io/ip)
    local SSH_SERVICE=$(get_ssh_service_name)

    echo "====== 开始 SSH 端口修改 ======"
    echo "🔧 目标端口: $NEWPORT"
    echo "📌 SSH 服务: $SSH_SERVICE"
    echo "🌐 公网 IP: $REMOTE_IP"
    
    # 检查是否使用 socket activation
    if systemctl is-enabled ${SSH_SERVICE}.socket >/dev/null 2>&1; then
        echo ""
        echo "⚠️  检测到系统使用 socket activation"
        echo "🔧 禁用 socket activation，切换到传统模式..."
        
        # 停止并禁用 socket
        sudo systemctl stop ${SSH_SERVICE}.socket 2>/dev/null || true
        sudo systemctl disable ${SSH_SERVICE}.socket 2>/dev/null || true
        sudo systemctl mask ${SSH_SERVICE}.socket 2>/dev/null || true
        
        echo "✔ 已禁用 socket activation"
    fi
    
    # 显示当前状态
    echo ""
    echo "📋 当前 SSH 配置中的端口："
    sudo grep -E "^Port|^#Port" "$SSHCFG" || echo "未找到 Port 配置"
    
    # 备份配置
    sudo cp "$SSHCFG" "$BACKUP"
    echo "✔ 已备份配置到 $BACKUP"

    # 修改配置
    echo ""
    echo "🔧 修改 SSH 配置..."
    
    # 删除所有 Port 行
    sudo sed -i '/^#*Port\s/d' "$SSHCFG"
    
    # 在文件开头添加新端口
    sudo sed -i "1iPort $NEWPORT" "$SSHCFG"
    
    echo "✔ 已设置新端口 $NEWPORT"

    # 防火墙放行新端口
    echo ""
    echo "🔥 配置防火墙..."
    sudo ufw allow "$NEWPORT"/tcp >/dev/null 2>&1
    echo "✔ 防火墙已放行端口 $NEWPORT"

    # 检查 SSH 配置语法
    echo ""
    echo "🔍 检查 SSH 配置语法..."
    if ! sudo sshd -t 2>&1; then
        echo "❌ SSH 配置语法错误！"
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl enable ${SSH_SERVICE}.socket 2>/dev/null || true
        sudo systemctl unmask ${SSH_SERVICE}.socket 2>/dev/null || true
        sudo systemctl start ${SSH_SERVICE}.socket 2>/dev/null || true
        return 1
    fi
    echo "✔ SSH 配置语法正确"

    # 启用并启动 SSH 服务（传统模式）
    echo ""
    echo "🔄 启动 SSH 服务（传统模式）..."
    sudo systemctl enable ${SSH_SERVICE}.service
    sudo systemctl restart ${SSH_SERVICE}.service
    sleep 3
    
    # 检查服务状态
    echo ""
    echo "📋 SSH 服务状态："
    sudo systemctl status ${SSH_SERVICE}.service --no-pager -l | head -15
    
    # 等待并检查端口监听
    echo ""
    echo "⏳ 等待 SSH 服务监听新端口..."
    local retry=0
    local max_retries=15
    local found=0
    
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        sleep 1
        
        echo -n "."
        
        # 检查端口监听
        if sudo ss -tlnp | grep -E ":$NEWPORT\s" >/dev/null 2>&1; then
            found=1
            break
        fi
        
        if sudo lsof -iTCP:"$NEWPORT" -sTCP:LISTEN >/dev/null 2>&1; then
            found=1
            break
        fi
    done
    
    echo ""
    
    if [ $found -eq 0 ]; then
        echo ""
        echo "❌ SSH 服务未在端口 $NEWPORT 上监听"
        echo ""
        echo "📋 当前监听端口："
        sudo ss -tlnp | grep -i ssh
        echo ""
        echo "📋 最近日志："
        sudo journalctl -u ${SSH_SERVICE}.service -n 20 --no-pager
        echo ""
        echo "🔙 回滚配置..."
        sudo mv "$BACKUP" "$SSHCFG"
        sudo systemctl enable ${SSH_SERVICE}.socket 2>/dev/null || true
        sudo systemctl unmask ${SSH_SERVICE}.socket 2>/dev/null || true
        sudo systemctl stop ${SSH_SERVICE}.service
        sudo systemctl start ${SSH_SERVICE}.socket
        echo "✔ 已回滚"
        return 1
    fi
    
    echo "✔ SSH 已在本地监听端口 $NEWPORT"
    
    echo ""
    echo "📋 当前监听端口："
    sudo ss -tlnp | grep -i ssh

    # 远程连接测试
    if [ -n "$REMOTE_IP" ] && [ "$REMOTE_IP" != "127.0.0.1" ]; then
        echo ""
        echo "🌐 测试远程连接 $REMOTE_IP:$NEWPORT..."
        if timeout 5 bash -c "echo >/dev/tcp/$REMOTE_IP/$NEWPORT" 2>/dev/null; then
            echo "✔ 远程连接测试成功"
        else
            echo "⚠ 无法通过公网 IP 连接（可能需要在云服务商安全组开放端口）"
            read -p "本地测试已通过，是否继续？ [Y/n]: " confirm
            if [[ ! -z "$confirm" && ! "$confirm" =~ ^[Yy]$ ]]; then
                sudo mv "$BACKUP" "$SSHCFG"
                sudo systemctl enable ${SSH_SERVICE}.socket 2>/dev/null || true
                sudo systemctl unmask ${SSH_SERVICE}.socket 2>/dev/null || true
                sudo systemctl stop ${SSH_SERVICE}.service
                sudo systemctl start ${SSH_SERVICE}.socket
                echo "✔ 已回滚"
                return 1
            fi
        fi
    fi

    sudo rm -f "$BACKUP"
    echo ""
    echo "✅ SSH 端口已成功修改为 $NEWPORT"
    echo "====== SSH 端口修改完成 ======"
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

    echo ""
    echo "🔒 开始安全修改 SSH 端口..."
    echo ""
    if safe_modify_ssh_port "$SSH_PORT"; then
        echo ""
        echo "✔ SSH 端口已安全切换为 $SSH_PORT"
    else
        echo ""
        echo "⚠ SSH 端口修改失败，已回滚，使用原端口继续"
    fi

    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo ""
    echo "🎉 VPS 初始化完成！"
    echo "=============================="
    echo "用户名: $USERNAME"
    echo "随机密码: $RANDOM_PASS"
    echo "SSH 端口: $SSH_PORT"
    echo "=============================="
    echo "请使用命令登录："
    echo "ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
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
