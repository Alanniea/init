#!/usr/bin/env bash
set -euo pipefail

############################
# VPS 一键初始化脚本
# 功能：
# - 创建用户（默认 aleta）
# - 设置 SSH 端口（默认 21357）
# - 安装并配置公钥登录（可从常见位置读取或粘贴）
# - 启用免密 sudo
# - 安装 fail2ban
# - 使用 UFW 放行 80/443 和 SSH 端口
# - 生成并显示随机密码
############################

# --- helper
info()  { echo -e "\\e[1;34m[INFO]\\e[0m $*"; }
warn()  { echo -e "\\e[1;33m[WARN]\\e[0m $*"; }
error() { echo -e "\\e[1;31m[ERROR]\\e[0m $*"; exit 1; }

# require root
if [[ $EUID -ne 0 ]]; then
  error "请以 root 身份运行脚本 (sudo)."
fi

read -r -p "用户名 (默认: aleta): " INPUT_USER
USER_NAME="${INPUT_USER:-aleta}"

read -r -p "SSH 端口 (默认: 21357): " INPUT_PORT
SSH_PORT="${INPUT_PORT:-21357}"

echo
info "将尝试从以下位置读取公钥（若存在）："
CANDIDATE_KEYS=()
# If script run with sudo, SUDO_USER points to original user
orig_user="${SUDO_USER:-}"
if [[ -n "$orig_user" ]]; then
  CANDIDATE_KEYS+=("/home/${orig_user}/.ssh/id_rsa.pub")
  CANDIDATE_KEYS+=("/home/${orig_user}/.ssh/id_ed25519.pub")
fi
CANDIDATE_KEYS+=("/root/.ssh/id_rsa.pub" "/root/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub")

for k in "${CANDIDATE_KEYS[@]}"; do
  echo " - $k"
done

read -r -p "如果要从文件读取，输入文件路径并回车；直接回车将尝试上面位置；或粘贴公钥并以 CTRL-D 结束： " KEY_INPUT

PUBKEY=""
if [[ -n "$KEY_INPUT" ]]; then
  # if input looks like a path and file exists, read it; else treat as pasted key
  if [[ -f "$KEY_INPUT" ]]; then
    PUBKEY="$(<"$KEY_INPUT")"
  else
    info "检测为粘贴公钥；读取粘贴内容，结束请按 CTRL-D"
    # read until EOF
    pasted="$(cat -)"
    PUBKEY="$pasted"
  fi
else
  # try candidate files in order
  for k in "${CANDIDATE_KEYS[@]}"; do
    if [[ -f "$k" ]]; then
      info "从 $k 读取公钥"
      PUBKEY="$(<"$k")"
      break
    fi
  done
fi

if [[ -z "${PUBKEY// /}" ]]; then
  warn "未检测到公钥内容 —— 将创建用户但不会安装 authorized_keys（你以后可手动添加公钥）。"
else
  # trim whitespace
  PUBKEY="$(echo "$PUBKEY" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
fi

# Confirm
echo
info "将创建用户: $USER_NAME"
info "SSH 将改为端口: $SSH_PORT"
if [[ -n "$PUBKEY" ]]; then
  info "将安装提供的公钥到 /home/$USER_NAME/.ssh/authorized_keys"
else
  warn "没有提供公钥 — 请在创建后手动添加公钥以免被锁定。"
fi

read -r -p "继续执行吗？ (Y/n): " _cont
_cont="${_cont:-Y}"
if [[ "$_cont" =~ ^[Nn] ]]; then
  error "已取消。"
fi

# --- create user if not exists
if id "$USER_NAME" &>/dev/null; then
  warn "用户 $USER_NAME 已存在，脚本将更新该用户的设置（公钥、sudo、密码等）。"
  NEW_CREATED=false
else
  info "创建用户 $USER_NAME ..."
  useradd -m -s /bin/bash -G sudo "$USER_NAME"
  NEW_CREATED=true
fi

# --- generate random password for the user
RANDOM_PASSWORD="$(openssl rand -base64 18 | tr -d '\n' )"
echo "${USER_NAME}:${RANDOM_PASSWORD}" | chpasswd

# Create .ssh and authorized_keys if pubkey provided
if [[ -n "$PUBKEY" ]]; then
  info "设置 $USER_NAME 的 SSH 公钥..."
  user_ssh_dir="/home/$USER_NAME/.ssh"
  mkdir -p "$user_ssh_dir"
  chmod 700 "$user_ssh_dir"
  printf "%s\n" "$PUBKEY" > "$user_ssh_dir/authorized_keys"
  chown -R "$USER_NAME:$USER_NAME" "$user_ssh_dir"
  chmod 600 "$user_ssh_dir/authorized_keys"
fi

# --- enable passwordless sudo
info "为 $USER_NAME 配置免密 sudo (/etc/sudoers.d/010-$USER_NAME)..."
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/010-$USER_NAME"
chmod 440 "/etc/sudoers.d/010-$USER_NAME"

# --- apt update and install packages
info "更新 apt 索引并安装 fail2ban 和 ufw"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban ufw

# --- configure UFW: allow ports
info "配置 UFW：允许 SSH($SSH_PORT), 80, 443"
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp

# Enable UFW if not enabled
ufw_status="$(ufw status | head -n1 || true)"
if [[ "$ufw_status" == "Status: inactive" ]]; then
  info "启用 UFW..."
  ufw --force enable
else
  info "UFW 已启用，已添加规则。"
fi

# --- configure sshd
SSHD_CONF="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
info "备份 sshd 配置到 $BACKUP"
cp -a "$SSHD_CONF" "$BACKUP"

info "更新 $SSHD_CONF：设置 Port $SSH_PORT，确保允许公钥认证并禁用密码认证（强烈建议公钥已安装）"
# helper to set or append settings
set_or_replace() {
  local key="$1"; local val="$2"
  if grep -qiE "^\\s*#?\\s*${key}\\b" "$SSHD_CONF"; then
    sed -ri "s|^\\s*#?\\s*${key}\\b.*|${key} ${val}|I" "$SSHD_CONF"
  else
    echo "${key} ${val}" >> "$SSHD_CONF"
  fi
}

set_or_replace Port "$SSH_PORT"
set_or_replace PubkeyAuthentication "yes"
# We'll disable password authentication to force key usage; if no key provided we keep it enabled
if [[ -n "$PUBKEY" ]]; then
  set_or_replace PasswordAuthentication "no"
else
  warn "没有提供公钥，保留 PasswordAuthentication（避免将你锁死）。"
  # ensure PasswordAuthentication yes
  set_or_replace PasswordAuthentication "yes"
fi
# Ensure AuthorizedKeysFile has the default (for compatibility)
set_or_replace AuthorizedKeysFile ".ssh/authorized_keys"

# Restart SSH
info "重启 ssh 服务"
if systemctl list-unit-files | grep -q sshd; then
  systemctl restart sshd
else
  systemctl restart ssh || true
fi

# --- fail2ban basic enable (use default jail.local if none exists)
info "确保 fail2ban 正常启动"
systemctl enable --now fail2ban || true

# --- summary
echo
echo "========================================"
info "初始化完成（摘要）："
echo "  用户名:      $USER_NAME"
echo "  SSH 端口:    $SSH_PORT"
if [[ -n "$PUBKEY" ]]; then
  echo "  公钥:        已安装到 /home/$USER_NAME/.ssh/authorized_keys"
else
  echo "  公钥:        未安装（请手动添加）"
fi
echo "  fail2ban:    已安装并尝试启用"
echo "  防火墙 (UFW): 已启用并放行 80, 443 和 $SSH_PORT"
echo
echo "  ${USER_NAME} 的随机密码（请保存）："
echo
echo "  >>> ${RANDOM_PASSWORD} <<<"
echo
primary_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "$primary_ip" ]]; then
  echo "连接示例："
  echo "  ssh -i ~/.ssh/id_rsa -p ${SSH_PORT} ${USER_NAME}@${primary_ip}"
else
  echo "请使用你的 VPS IP（或域名）连接： ssh -i ~/.ssh/id_rsa -p ${SSH_PORT} ${USER_NAME}@<your-server-ip>"
fi
echo
warn "重要：如果你未提供公钥，请务必通过控制面板或控制台添加公钥以避免被锁定。"
echo "========================================"
