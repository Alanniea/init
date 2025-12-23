#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}>>> VPS 一键初始化脚本启动...${NC}"

# 1. 交互式获取参数
read -p "请输入要创建的用户名 [默认: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "请输入 SSH 端口 [默认: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

# 2. 生成随机密码
RANDOM_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 16)

# 3. 更新系统并安装必要工具
echo -e "${GREEN}>>> 更新系统并安装必要组件...${NC}"
apt update && apt install -y sudo ufw fail2ban

# 4. 创建用户并配置免密 sudo
echo -e "${GREEN}>>> 创建用户 ${USERNAME}...${NC}"
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"

# 5. 配置 SSH 公钥登录
# 提示：请确保你已经在本地执行了 cat ~/.ssh/id_rsa.pub 并准备好内容
echo -e "${RED}请粘贴你的本地公钥 (~/.ssh/id_rsa.pub 的内容):${NC}"
read -r SSH_KEY

USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. 安全配置 SSH 服务
echo -e "${GREEN}>>> 配置 SSH 端口为 ${SSH_PORT} 并禁用密码登录...${NC}"
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart ssh

# 7. 配置防火墙 (UFW)
echo -e "${GREEN}>>> 配置 UFW 防火墙...${NC}"
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 8. 启动并配置 Fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# 完成报告
echo -e "\n-----------------------------------------------"
echo -e "${GREEN}初始化完成！${NC}"
echo -e "用户名: ${USERNAME}"
echo -e "临时密码: ${RED}${RANDOM_PASS}${NC} (建议仅作备用)"
echo -e "SSH 端口: ${SSH_PORT}"
echo -e "状态: 已启用公钥登录，已禁用密码登录，已开启防火墙。"
echo -e "-----------------------------------------------"
echo -e "请使用以下命令连接: ${GREEN}ssh -p ${SSH_PORT} ${USERNAME}@{你的服务器IP}${NC}"
