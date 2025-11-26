#!/usr/bin/env bash
set -euo pipefail

############################
# VPS 一键初始化脚本（含“安全重启” ssh 逻辑）
# 功能：
# - 创建用户（默认 aleta）
# - 设置 SSH 端口（默认 21357）
# - 安装并配置公钥登录（可从常见位置读取或粘贴）
# - 启用免密 sudo
# - 安装 fail2ban
# - 使用 UFW 放行 80/443 和 SSH 端口
# - 生成并显示随机密码
# - 在修改 sshd_config 后进行语法校验，只有校验通过才重启；否则回滚备份
############################

# --- helper
info()  { echo -e "\\e[1;34m[INFO]\\e[0m $*"; }
warn()  { echo -e "\\e[1;33m[WARN]\\e[0m $*"; }
error() { echo -e "\\e[1;31m[ERROR]\\e[0m $*" ; exit 1; }

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
  if [[ -f "$KEY_INPUT" ]]; then
    PUBKEY="$(<"$KEY_INPUT")"
  else
    info "检测为粘贴公钥；读取粘贴内容，结束请按 CTRL-D"
    pasted="$(cat -)"
    PUBKEY="$pasted"
  fi
else
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
  PUBKEY="$(echo "$PUBKEY" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
fi

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
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban ufw openssl

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

info "更新 $SSHD_CONF：设置 Port $SSH_PORT，确保允许公钥认证并根据是否提供公钥决定是否禁用密码认证"

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
if [[ -n "$PUBKEY" ]]; then
  set_or_replace PasswordAuthentication "no"
else
  warn "没有提供公钥，保留 PasswordAuthentication（避免将你锁死）。"
  set_or_replace PasswordAuthentication "yes"
fi
set_or_replace AuthorizedKeysFile ".ssh/authorized_keys"

# --- 安全重启逻辑：校验 -> 重启 -> 失败回滚
SSHD_TEST_ERR="/tmp/sshd_test.err"
SSHD_RESTART_ERR="/tmp/sshd_restart.err"

# 清理旧的临时文件（非必须）
: > "$SSHD_TEST_ERR" 2>/dev/null || true
: > "$SSHD_RESTART_ERR" 2>/dev/null || true

info "验证 sshd 配置语法..."
if sshd -t 2>"$SSHD_TEST_ERR"; then
  info "sshd_config 语法检查通过，尝试重启 ssh 服务..."
  # 优先使用 systemctl reload-or-restart（如果可用），回退到 restart 或 service
  if command -v systemctl >/dev/null 2>&1; then
    # try reload-or-restart if available
    if systemctl --version >/dev/null 2>&1 && systemctl reload-or-restart sshd.service 2>>"$SSHD_RESTART_ERR"; then
      info "ssh 服务已通过 systemctl reload-or-restart sshd.service 成功重载/重启。"
    else
      # 有些系统没实现 reload-or-restart，尝试 restart
      if systemctl restart sshd.service 2>>"$SSHD_RESTART_ERR" || systemctl restart ssh.service 2>>"$SSHD_RESTART_ERR"; then
        info "ssh 服务已通过 systemctl restart 成功重启。"
      else
        warn "使用 systemctl 重启失败，尝试传统 service 命令..."
        if service ssh restart 2>>"$SSHD_RESTART_ERR" || service sshd restart 2>>"$SSHD_RESTART_ERR" || /etc/init.d/ssh restart 2>>"$SSHD_RESTART_ERR"; then
          info "ssh 服务通过 service 重启成功。"
        else
          error "重启 ssh 失败，请查看 $SSHD_RESTART_ERR 和 $SSHD_TEST_ERR 获取详情。"
        fi
      fi
    fi
  else
    # 无 systemctl 的环境
    if service ssh restart 2>>"$SSHD_RESTART_ERR" || service sshd restart 2>>"$SSHD_RESTART_ERR" || /etc/init.d/ssh restart 2>>"$SSHD_RESTART_ERR"; then
      info "ssh 服务已重启（无 systemd 环境）。"
    else
      error "重启 ssh 失败（无 systemd），请检查 $SSHD_RESTART_ERR 和 $SSHD_TEST_ERR。"
    fi
  fi
else
  echo "========================================"
  error "sshd_config 语法校验失败，重启已中止。错误已写入 $SSHD_TEST_ERR"
  echo "将 $SSHD_CONF 还原到备份 $BACKUP"
  cp -a "$BACKUP" "$SSHD_CONF"
  # 尝试用旧配置再启动（以保证现有连接不被切断）
  info "尝试使用备份配置重启 ssh（以保留当前会话）..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart sshd.service 2>>"$SSHD_RESTART_ERR" || systemctl restart ssh.service 2>>"$SSHD_RESTART_ERR" || true
  else
    service ssh restart 2>>"$SSHD_RESTART_ERR" || /etc/init.d/ssh restart 2>>"$SSHD_RESTART_ERR" || true
  fi
  error "已回滚配置并退出。请查看 $SSHD_TEST_ERR 和 $SSHD_RESTART_ERR 以诊断问题。"
fi

# --- ensure fail2ban enabled
info "确保 fail2ban 正常启动"
systemctl enable --now fail2ban >/dev/null 2>&1 || true

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
echo "如果遇到 ssh 无法连接，请使用托管商的控制台/串口登陆查看 $SSHD_TEST_ERR 和 $SSHD_RESTART_ERR。"
echo "========================================"
