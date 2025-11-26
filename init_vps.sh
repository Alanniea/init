#!/usr/bin/env bash
set -e

echo "=========================================="
echo "🚀 Linux VPS 初始化脚本（跨系统适配版）"
echo "用户: aleta"
echo "SSH 端口: 21357"
echo "=========================================="
read -rp "确认执行初始化？(y/N): " yn
[[ "$yn" != "y" && "$yn" != "Y" ]] && echo "已取消。" && exit 0


###############################################
# 1️⃣ 生成随机密码
###############################################
RANDOM_PASS=$(openssl rand -base64 18)
echo "👉 已生成随机密码"


###############################################
# 2️⃣ 创建用户
###############################################
if id "aleta" &>/dev/null; then
    echo "用户 aleta 已存在，跳过。"
else
    adduser --disabled-password --gecos "" aleta
    echo "aleta:$RANDOM_PASS" | chpasswd
    echo "✔ 用户 aleta 已创建"
fi


###############################################
# 3️⃣ sudo 免密
###############################################
echo "aleta ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-aleta
chmod 440 /etc/sudoers.d/90-aleta
echo "✔ 已启用 sudo 免密"


###############################################
# 4️⃣ 导入 SSH 公钥
###############################################
sudo -u aleta mkdir -p /home/aleta/.ssh
sudo -u aleta chmod 700 /home/aleta/.ssh

if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    sudo -u aleta cp "$HOME/.ssh/id_rsa.pub" /home/aleta/.ssh/authorized_keys
else
    echo "未找到 ~/.ssh/id_rsa.pub"
    read -rp "请手动输入公钥: " pub
    echo "$pub" | sudo -u aleta tee /home/aleta/.ssh/authorized_keys >/dev/null
fi

sudo -u aleta chmod 600 /home/aleta/.ssh/authorized_keys
echo "✔ SSH 公钥已配置"


###############################################
# 5️⃣ 自动识别系统类型
###############################################
if command -v apt &>/dev/null; then
    OS="debian"
elif command -v yum &>/dev/null; then
    OS="centos"
else
    echo "无法识别系统，请检查。"
    exit 1
fi

echo "🔍 检测到系统类型: $OS"


###############################################
# 6️⃣ 修改 SSH 配置
###############################################
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"

# 修改端口 & 禁用 root 登录
sed -i "s/^#Port .*/Port 21357/" "$SSHD_CONFIG"
sed -i "s/^Port .*/Port 21357/" "$SSHD_CONFIG"

sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
sed -i "s/^PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"


###############################################
# 7️⃣ 自动判断 ssh / sshd 服务名
###############################################
restart_ssh() {
    if systemctl list-unit-files | grep -q "^ssh.service"; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files | grep -q "^sshd.service"; then
        SSH_SERVICE="sshd"
    else
        echo "❌ 未找到 ssh/sshd 服务"
        return 1
    fi

    echo "🔄 正在重启 SSH: $SSH_SERVICE"
    systemctl restart "$SSH_SERVICE"
    sleep 1

    if ! systemctl is-active "$SSH_SERVICE" >/dev/null; then
        echo "❌ SSH 重启失败！正在恢复原配置…"
        cp "$SSHD_CONFIG.bak" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE"
        echo "⚠ SSH 已恢复到原始状态，请检查配置。"
        exit 1
    fi

    echo "✔ SSH 重启成功"
}


restart_ssh


###############################################
# 8️⃣ 安装 fail2ban
###############################################
if [ "$OS" = "debian" ]; then
    apt update -y
    apt install -y fail2ban
else
    yum install -y epel-release
    yum install -y fail2ban
    systemctl enable --now fail2ban
fi

echo "✔ fail2ban 已安装"


###############################################
# 9️⃣ 配置防火墙
###############################################
if command -v ufw &>/dev/null; then
    ufw allow 21357/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    echo "✔ UFW 已放行端口"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=21357/tcp
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    echo "✔ firewalld 已放行端口"
else
    echo "⚠ 未找到防火墙，跳过"
fi


###############################################
# 10️⃣ 完成提示
###############################################
echo "=========================================="
echo "🎉 初始化完成！请保存以下信息："
echo "用户: aleta"
echo "SSH 端口: 21357"
echo "随机密码: $RANDOM_PASS"
echo "=========================================="
echo "现在可以尝试使用新用户登录。"
