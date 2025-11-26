#!/bin/bash

# 定义颜色以便输出更清晰
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. 检查是否以 Root 运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 用户运行此脚本 (sudo bash ...)${NC}"
   exit 1
fi

echo -e "${GREEN}>>> 开始 Ubuntu VPS 初始化配置...${NC}"

# 变量设置
USERNAME="aleta"
SSH_PORT="21357"

# 2. 交互式获取公钥
echo -e "${YELLOW}请粘贴你的公钥内容 (来自 ~/.ssh/id_rsa.pub) 然后按回车:${NC}"
read PUB_KEY

if [[ -z "$PUB_KEY" ]]; then
    echo -e "${RED}错误：公钥不能为空！脚本已终止。${NC}"
    exit 1
fi

# 3. 更新系统源 (可选，为了速度这里仅 update)
echo -e "${GREEN}>>> 更新软件包列表...${NC}"
apt-get update -y

# 4. 安装必要的软件
echo -e "${GREEN}>>> 安装 UFW 和 Fail2Ban...${NC}"
apt-get install -y ufw fail2ban openssl

# 5. 创建用户并生成随机密码
echo -e "${GREEN}>>> 创建用户 ${USERNAME}...${NC}"
PASSWORD=$(openssl rand -base64 16)

# 创建用户 (如果不存在)
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}用户 ${USERNAME} 已存在，跳过创建。${NC}"
else
    useradd -m -s /bin/bash "$USERNAME"
fi

# 设置密码
echo "$USERNAME:$PASSWORD" | chpasswd

# 6. 配置 SSH 密钥
echo -e "${GREEN}>>> 配置 SSH 密钥...${NC}"
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"

# 设置正确的权限
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"

# 7. 配置免密 Sudo
echo -e "${GREEN}>>> 配置免密 Sudo...${NC}"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 8. 配置 SSH 端口和安全设置
echo -e "${GREEN}>>> 修改 SSH 配置 (端口: ${SSH_PORT})...${NC}"
SSHD_CONFIG="/etc/ssh/sshd_config"

# 备份配置文件
cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"

# 修改端口 (如果 Port 22 存在则替换，否则追加)
if grep -q "^Port 22" $SSHD_CONFIG; then
    sed -i "s/^Port 22/Port $SSH_PORT/" $SSHD_CONFIG
elif grep -q "^#Port 22" $SSHD_CONFIG; then
    sed -i "s/^#Port 22/Port $SSH_PORT/" $SSHD_CONFIG
else
    echo "Port $SSH_PORT" >> $SSHD_CONFIG
fi

# 禁用 Root 登录 (建议)
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' $SSHD_CONFIG

# 9. 配置防火墙 (UFW)
echo -e "${GREEN}>>> 配置 UFW 防火墙...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 10. 配置 Fail2Ban 监控新端口
echo -e "${GREEN}>>> 配置 Fail2Ban...${NC}"
# 创建一个专门的配置文件来覆盖默认 sshd 设置
cat > /etc/fail2ban/jail.d/custom-sshd.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 1h
EOF

systemctl restart fail2ban

# 11. 重启 SSH 服务
echo -e "${GREEN}>>> 重启 SSH 服务...${NC}"
systemctl restart ssh

# 12. 输出结果
echo -e "\n--------------------------------------------------"
echo -e "${GREEN}✅ 初始化完成！${NC}"
echo -e "--------------------------------------------------"
echo -e "用户名     : ${YELLOW}${USERNAME}${NC}"
echo -e "随机密码   : ${YELLOW}${PASSWORD}${NC} (请立即保存!)"
echo -e "SSH 端口   : ${YELLOW}${SSH_PORT}${NC}"
echo -e "SSH 连接命令:"
echo -e "${YELLOW}ssh ${USERNAME}@$(curl -s ifconfig.me) -p ${SSH_PORT} -i ~/.ssh/id_rsa${NC}"
echo -e "--------------------------------------------------"
echo -e "${RED}注意：请在断开当前连接前，新开一个终端测试能否成功登录！${NC}"
