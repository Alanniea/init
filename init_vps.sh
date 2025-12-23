#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Ubuntu VPS 一键初始化 (跳过权限自检模式) ===${NC}"

# 1. 交互式输入
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入自定义 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

read -p "请粘贴您的本地公钥 (id_rsa.pub 内容): " SSH_KEY

if [[ -z "$SSH_KEY" ]]; then
    echo -e "${RED}错误: 公钥不能为空，脚本退出。${NC}"
    exit 1
fi

# 2. 生成随机密码
PASSWORD=$(openssl rand -base64 16)

# 3. 创建新用户并设置
echo -e "${YELLOW}正在创建用户 ${USERNAME}...${NC}"
sudo useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | sudo chpasswd
sudo usermod -aG sudo "$USERNAME"

# 4. 配置免密 sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$USERNAME" > /dev/null

# 5. 配置 SSH 公钥登录
USER_HOME=$(eval echo "~$USERNAME")
sudo mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" | sudo tee "$USER_HOME/.ssh/authorized_keys" > /dev/null
sudo chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
sudo chmod 700 "$USER_HOME/.ssh"
sudo chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. 修改 SSH 配置 (禁用密码登录，禁用 root 登录)
echo -e "${YELLOW}正在配置 SSH 安全项 (端口: $SSH_PORT)...${NC}"
sudo sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo systemctl restart ssh

# 7. 配置 UFW 防火墙
echo -e "${YELLOW}正在配置防火墙...${NC}"
sudo ufw allow "$SSH_PORT"/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# 8. 安装 fail2ban
echo -e "${YELLOW}正在安装并启动 fail2ban...${NC}"
sudo apt update && sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# 完成总结
echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}初始化完成！请记录以下信息：${NC}"
echo -e "------------------------------------------"
echo -e "新用户名:  ${YELLOW}$USERNAME${NC}"
echo -e "临时密码:  ${YELLOW}$PASSWORD${NC} (已配置免密sudo)"
echo -e "SSH 端口:  ${YELLOW}$SSH_PORT${NC}"
echo -e "登录命令:  ${GREEN}ssh -p $SSH_PORT $USERNAME@服务器IP${NC}"
echo -e "------------------------------------------"
echo -e "${RED}警告: 在确认新用户能登录前，请勿关闭当前会话！${NC}"
echo -e "${GREEN}==========================================${NC}"
