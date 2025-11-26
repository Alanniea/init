#!/usr/bin/env bash
set -e

echo "========================================"
echo "🚀 Ubuntu VPS 初始化脚本"
echo "用户: aleta"
echo "SSH 端口: 21357"
echo "公钥路径: ~/.ssh/id_rsa.pub"
echo "========================================"
read -rp "确认执行初始化？(y/N): " yn
[[ "$yn" != "y" && "$yn" != "Y" ]] && echo "已取消。" && exit 0


# ------------------------------
# 1️⃣ 生成随机密码
# ------------------------------
RANDOM_PASS=$(openssl rand -base64 18)
echo "👉 已生成随机密码"


# ------------------------------
# 2️⃣ 创建用户 aleta
# ------------------------------
if id "aleta" &>/dev/null; then
    echo "用户 aleta 已存在，跳过创建。"
else
    adduser --disabled-password --gecos "" aleta
    echo "aleta:$RANDOM_PASS" | chpasswd
    echo "用户 aleta 已创建 ✔"
fi


# ------------------------------
# 3️⃣ 授权免密 sudo
# ------------------------------
echo "aleta ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-aleta
chmod 440 /etc/sudoers.d/90-aleta
echo "已启用 sudo 免密 ✔"


# ------------------------------
# 4️⃣ 设置 SSH 公钥
# ------------------------------
sudo -u aleta mkdir -p /home/aleta/.ssh
sudo -u aleta chmod 700 /home/aleta/.ssh

if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    sudo -u aleta cp "$HOME/.ssh/id_rsa.pub" /home/aleta/.ssh/authorized_keys
else
    read -rp "未找到本地公钥。请手动输入你的公钥: " pub
    echo "$pub" | sudo -u aleta tee /home/aleta/.ssh/authorized_keys >/dev/null
fi

sudo -u aleta chmod 600 /home/aleta/.ssh/authorized_keys
echo "SSH 公钥已配置 ✔"


# ------------------------------
# 5️⃣ 修改 SSH 端口 & 禁用 root 登录
# ------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
cp $SSHD_CONFIG ${SSHD_CONFIG}.bak

sed -i "s/^#Port .*/Port 21357/" $SSHD_CONFIG
sed -i "s/^Port .*/Port 21357/" $SSHD_CONFIG

sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" $SSHD_CONFIG
sed -i "s/^PermitRootLogin .*/PermitRootLogin no/" $SSHD_CONFIG

systemctl restart sshd
echo "SSH 已改为端口 21357，已禁用 root 登录 ✔"


# ------------------------------
# 6️⃣ 安装 fail2ban
# ------------------------------
apt update -y
apt install -y fail2ban
systemctl enable --now fail2ban
echo "fail2ban 已安装 ✔"


# ------------------------------
# 7️⃣ 配置防火墙
# ------------------------------
ufw allow 21357/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "UFW 已放行 21357/80/443 ✔"


# ------------------------------
# 8️⃣ 完成
# ------------------------------
echo "=========================================="
echo "🎉 初始化完成！登录信息如下："
echo "用户: aleta"
echo "初始随机密码: $RANDOM_PASS"
echo "SSH 端口: 21357"
echo "=========================================="
echo "请务必保存好密码！"
