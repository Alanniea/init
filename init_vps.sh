#!/usr/bin/env bash
set -euo pipefail

# Interactive Ubuntu VPS init script
# Creates a user, sets SSH port, copies public key, enables passwordless sudo,
# installs fail2ban and configures UFW for 80/443 and the SSH port.
#
# Tested on Ubuntu 18.04/20.04/22.04/24.04.

# --- helpers ---
info() { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[31m[ERROR]\e[0m $*"; }

# must be root
if [ "$EUID" -ne 0 ]; then
  err "请以 root 或 sudo 权限运行本脚本：sudo bash ${0##*/}"
  exit 1
fi

# --- prompts with defaults ---
read -rp "请输入要创建的用户名 [aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -rp "请输入 SSH 端口 [21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

# Check for an existing public key on the machine
LOCAL_PUB="$HOME/.ssh/id_rsa.pub"
PUBKEY_CONTENT=""
if [ -f "$LOCAL_PUB" ]; then
  read -rp "检测到 $LOCAL_PUB，是否使用它作为 ${USERNAME} 的公钥？ [Y/n]: " usefile
  usefile=${usefile:-Y}
  if [[ "$usefile" =~ ^([yY]|)$ ]]; then
    PUBKEY_CONTENT="$(cat "$LOCAL_PUB")"
  fi
fi

if [ -z "$PUBKEY_CONTENT" ]; then
  echo
  warn "未检测到可用的本地公钥，或者你选择不使用本地公钥。"
  echo "请粘贴你的公钥（以 ssh-rsa 或 ssh-ed25519 开头）。完成后按回车，然后按 Ctrl-D 结束："
  echo "----- 开始粘贴公钥 -----"
  PUBKEY_CONTENT=""
  # read until EOF (Ctrl-D)
  while IFS= read -r line; do
    PUBKEY_CONTENT+="$line"$'\n'
  done
  echo "----- 公钥读取结束 -----"
fi

# basic sanity check for public key
if ! echo "$PUBKEY_CONTENT" | grep -qE 'ssh-(rsa|ed25519|dss|ecdsa)|^ecdsa-sha2'; then
  err "提供的内容看起来不是有效的 SSH 公钥。请重新运行脚本并提供有效公钥。"
  exit 1
fi

# --- create user ---
if id "$USERNAME" >/dev/null 2>&1; then
  warn "用户 $USERNAME 已存在，脚本将继续并覆盖其 .ssh/authorized_keys（若存在）并确保 sudo 无密码。"
else
  info "创建用户 $USERNAME ..."
  # create user without password prompt
  adduser --disabled-password --gecos "" "$USERNAME"
  ok "用户 $USERNAME 已创建。"
fi

# generate random password for the user (for information only)
RANDOM_PASS="$(openssl rand -base64 15 | tr -d '/+=' | cut -c1-14 || head -c 14 < /dev/urandom | base64 | tr -d '/+=' | cut -c1-14)"
echo "${USERNAME}:${RANDOM_PASS}" | chpasswd
ok "已为用户 $USERNAME 设置随机密码（见下方输出）。"

# ensure home dir ownership
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
# write authorized_keys
echo "$PUBKEY_CONTENT" > "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
ok "已把公钥写入 $USER_HOME/.ssh/authorized_keys 并设置权限。"

# add to sudo group and enable passwordless sudo
if groups "$USERNAME" | grep -q "\bsudo\b"; then
  warn "用户 $USERNAME 已在 sudo 组。"
else
  usermod -aG sudo "$USERNAME"
  ok "用户 $USERNAME 已加入 sudo 组。"
fi

SUDOER_FILE="/etc/sudoers.d/90_${USERNAME}_nopass"
cat > "$SUDOER_FILE" <<EOF
# Allow $USERNAME to run any command without password
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 "$SUDOER_FILE"
ok "已创建 $SUDOER_FILE，启用免密 sudo。"

# --- SSHD tweaks ---
SSHD_CONF="/etc/ssh/sshd_config"
bk="/root/sshd_config.bak.$(date +%s)"
cp -a "$SSHD_CONF" "$bk"
info "备份原始 sshd_config 到 $bk"

# helper to set or replace config key
set_sshd_config() {
  local key="$1"; local val="$2"
  if grep -qE "^[#\s]*${key}\b" "$SSHD_CONF"; then
    sed -ri "s@^[#\s]*(${key})\b.*@\\1 $val@g" "$SSHD_CONF"
  else
    echo "${key} ${val}" >> "$SSHD_CONF"
  fi
}

set_sshd_config "Port" "$SSH_PORT"
set_sshd_config "PermitRootLogin" "no"
set_sshd_config "PasswordAuthentication" "no"
set_sshd_config "ChallengeResponseAuthentication" "no"
set_sshd_config "PubkeyAuthentication" "yes"
set_sshd_config "UsePAM" "yes"
# optionally restrict login to the created user only (commented out by default)
# set_sshd_config "AllowUsers" "$USERNAME"

ok "已更新 $SSHD_CONF（设置端口 $SSH_PORT，禁用 root 密码登录，禁用密码认证，开启公钥认证）。"

# restart sshd (use systemctl if available)
if command -v systemctl >/dev/null 2>&1; then
  info "重启 sshd ..."
  systemctl restart sshd
else
  info "使用 service 重启 ssh ..."
  service ssh restart
fi
ok "sshd 已重启。注意：如果你的当前会话使用的是同一连接，可能会被断开。"

# --- firewall: ufw ---
info "安装并配置 ufw（防火墙）..."
apt-get update -y
apt-get install -y ufw

# allow ports
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp

# set default policies
ufw default deny incoming
ufw default allow outgoing

# enable if not enabled
ufw_status=$(ufw status verbose | head -n1 || true)
if echo "$ufw_status" | grep -qi "inactive"; then
  echo "y" | ufw enable >/dev/null 2>&1 || ufw --force enable
  ok "ufw 已启用并允许端口: SSH $SSH_PORT, 80, 443"
else
  ok "ufw 已在运行，规则已更新：允许 SSH $SSH_PORT, 80, 443"
fi

# --- fail2ban ---
info "安装并启用 fail2ban ..."
apt-get install -y fail2ban
systemctl enable --now fail2ban || true
ok "fail2ban 已安装并启动。"

# optional: create a minimal jail local to protect ssh
FAIL2BAN_LOCAL="/etc/fail2ban/jail.d/custom-ssh.conf"
cat > "$FAIL2BAN_LOCAL" <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
EOF
systemctl reload fail2ban || true
ok "已为 fail2ban 添加 sshd 端口配置 ($SSH_PORT)。"

# --- final summary ---
cat <<SUMMARY

初始化完成 ✅

用户信息：
  用户名:   $USERNAME
  家目录:   $USER_HOME
  SSH 端口: $SSH_PORT
  公钥:     已写入 $USER_HOME/.ssh/authorized_keys
  随机密码: $RANDOM_PASS   <-- 请妥善保存（建议仅用于控制面板或短期用途）

已安装 / 配置：
  - ufw 防火墙：允许端口 $SSH_PORT, 80, 443
  - fail2ban：已启用并保护 sshd（见 $FAIL2BAN_LOCAL）
  - sudo：用户 $USERNAME 可免密 sudo（文件 $SUDOER_FILE）

重要提醒：
  - 当前脚本禁用了密码登录（PasswordAuthentication no），建议仅用 SSH 公钥登录。
  - 修改 SSH 端口并重启 sshd 可能会导致当前 SSH 会话断开。若无法重新连接，请使用云服务控制台或终端访问修复。
  - 若你希望允许多个用户登录或恢复密码登录，请谨慎修改 /etc/ssh/sshd_config。

要查看 fail2ban 状态：
  sudo systemctl status fail2ban
要查看 ufw 规则：
  sudo ufw status verbose

SUMMARY

ok "脚本执行完毕。"
