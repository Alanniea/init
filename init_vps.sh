#!/usr/bin/env bash
set -e

echo "🚀 Ubuntu VPS 一键初始化脚本"

交互式确认

read -p "确认执行初始化脚本吗？(y/n): " confirm
if [[ "$confirm" != "y" ]]; then
echo "已取消。"
exit 1
fi

生成随机密码

PASSWORD=$(openssl rand -base64 12)
echo "生成的新用户随机密码: $PASSWORD"

1️⃣ 创建用户 aleta 并添加到 sudoers

echo "创建用户 aleta..."
if id "aleta" &>/dev/null; then
echo "用户 aleta 已存在"
else
sudo adduser --disabled-password --gecos "" aleta
fi
echo "设置随机密码..."
echo "aleta:$PASSWORD" | sudo chpasswd
echo "aleta ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/aleta

2️⃣ 配置 SSH

echo "配置 SSH..."
SSH_PORT=21357
sudo sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
sudo mkdir -p /home/aleta/.ssh
sudo cp ~/.ssh/id_rsa.pub /home/aleta/.ssh/authorized_keys
sudo chown -R aleta:aleta /home/aleta/.ssh
sudo chmod 700 /home/aleta/.ssh
sudo chmod 600 /home/aleta/.ssh/authorized_keys

3️⃣ 安装 fail2ban

echo "安装 fail2ban..."
sudo apt update
sudo apt install -y fail2ban

4️⃣ 配置防火墙

echo "配置 UFW..."
sudo apt install -y ufw
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow $SSH_PORT
sudo ufw --force enable

5️⃣ 重启 SSH

echo "重启 SSH 服务..."
sudo systemctl restart ssh

echo "✅ 初始化完成！"
echo "SSH 端口: $SSH_PORT"
echo "用户名: aleta"
echo "密码: $PASSWORD"
echo "请使用公钥登录，并建议立即修改密码。"
