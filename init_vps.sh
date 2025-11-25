#!/usr/bin/env bash
set -e

# ==== 默认参数，可在初始化时修改 ====
DEFAULT_USERNAME="aleta"
DEFAULT_SSH_PORT=21357
DEFAULT_LOCAL_SSH_KEY="$HOME/.ssh/id_rsa.pub"
# ======================================

function init_vps() {
    echo "🚀 VPS 初始化开始..."

    # 交互输入
    read -p "请输入新用户名 [默认: $DEFAULT_USERNAME]: " USERNAME
    USERNAME=${USERNAME:-$DEFAULT_USERNAME}

    read -p "请输入 SSH 端口 [默认: $DEFAULT_SSH_PORT]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}

    read -p "请输入本地 SSH 公钥路径 [默认: $DEFAULT_LOCAL_SSH_KEY]: " LOCAL_SSH_KEY
    LOCAL_SSH_KEY=${LOCAL_SSH_KEY:-$DEFAULT_LOCAL_SSH_KEY}

    # 更新系统
    sudo apt update && sudo apt upgrade -y

    # 创建用户
    sudo adduser --disabled-password --gecos "" $USERNAME
    echo "$USERNAME:$(openssl rand -base64 12)" | sudo chpasswd

    # 加入 sudo 并免密
    sudo usermod -aG sudo $USERNAME
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USERNAME >/dev/null

    # 配置 SSH Key
    sudo mkdir -p /home/$USERNAME/.ssh
    sudo cp "$LOCAL_SSH_KEY" /home/$USERNAME/.ssh/authorized_keys
    sudo chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    sudo chmod 700 /home/$USERNAME/.ssh
    sudo chmod 600 /home/$USERNAME/.ssh/authorized_keys

    # 修改 SSH 端口（保留 root 登录）
    sudo sed -i 's/^Port /#Port /' /etc/ssh/sshd_config
    echo "Port $SSH_PORT" | sudo tee -a /etc/ssh/sshd_config
    sudo systemctl restart ssh

    # 安装防火墙并启用
    sudo apt install -y ufw fail2ban
    sudo ufw allow $SSH_PORT/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable

    # 启用 fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    echo "✅ VPS 初始化完成！"
    echo "请使用命令登录：ssh -p $SSH_PORT $USERNAME@你的VPS_IP"
}

function main_menu() {
    while true; do
        echo ""
        echo "===== VPS 初始化菜单 ====="
        echo "1. 初始化 VPS"
        echo "2. 退出"
        read -p "请选择操作 [1-2]: " choice
        case $choice in
            1)
                init_vps
                ;;
            2)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo "无效选项，请重新输入"
                ;;
        esac
    done
}

# 运行主菜单
main_menu
