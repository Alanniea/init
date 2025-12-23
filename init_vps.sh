#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查是否为 root 运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 权限运行此脚本！${NC}"
   exit 1
fi

echo -e "${GREEN}=== Ubuntu VPS 一键初始化开始 ===${NC}"

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

# 3. 创建用户并设置
echo -e "${YELLOW}正在创建用户 ${USERNAME}...${NC}"
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME"

# 4. 配置免密 sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"

# 5. 配置 SSH 公钥登录
USER_HOME=$(eval echo "~$USERNAME")
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. 修改 SSH 配置
echo -e "${YELLOW}正在配置 SSH 安全项 (端口: $SSH_PORT)...${NC}"
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart ssh

# 7. 配置 UFW 防火墙
echo -e "${YELLOW}正在配置防火墙...${NC}"
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 8. 安装 fail2ban
echo -e "${YELLOW}正在安装并启动 fail2ban...${NC}"
apt update && apt install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# 完成总结
echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}初始化完成！请记录以下信息：${NC}"
echo -e "------------------------------------------"
echo -e "用户名:    ${YELLOW}$USERNAME${NC}"
echo -e "临时密码:  ${YELLOW}$PASSWORD${NC} (已启用免密sudo，仅作备用)"
echo -e "SSH 端口:  ${YELLOW}$SSH_PORT${NC}"
echo -e "登录命令:  ${CYAN}ssh -p $SSH_PORT $USERNAME@your_server_ip${NC}"
echo -e "------------------------------------------"
echo -e "${RED}警告: 请确保在退出当前会话前，通过新终端测试能否成功登录！${NC}"
echo -e "${GREEN}==========================================${NC}"
