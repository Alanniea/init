#!/usr/bin/env bash
# init_v2.sh — Ubuntu 一键初始化（用户 aleta，SSH 21357，公钥 ~/.ssh/id_rsa.pub，免密 sudo，fail2ban，UFW 放行 80/443）
# 兼容性：Ubuntu/Debian 风格系统（会尝试处理 ssh vs sshd 服务名）
# 用法：
#   sudo bash init_v2.sh         # 交互式（默认）
#   sudo NONINTERACTIVE=1 bash init_v2.sh   # 非交互式，使用默认选项
set -Eeuo pipefail

##########################
# ----- 配置区（可改）----
USERNAME="aleta"
SSH_PORT="21357"
PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"   # 会自动尝试 $SUDO_USER 的家目录
ENABLE_PASSWORD_LOGIN=false              # 不启用密码登录（脚本会设置为 no）
DISABLE_ROOT_LOGIN=true                  # 是否禁用 root 登录（交互可覆盖）
GENERATE_PASSWORD=true                    # 是否生成随机密码并设置为用户初始密码
USE_UFW=true                              # 是否使用 ufw（若无则安装）
INSTALL_FAIL2BAN=true                     # 是否安装 fail2ban
NONINTERACTIVE="${NONINTERACTIVE:-0}"     # 环境变量传入可设为 1 跳过提示
##########################

# 记时/日志
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log () { echo -e "[$(timestamp)] $*"; }

# 确保以 root 运行
if [[ "$(id -u)" -ne 0 ]]; then
  echo "请以 root 或 sudo 运行此脚本。"
  exit 1
fi

# 帮助定位运行者的公钥位置（优先 SUDO_USER）
if [[ -n "${SUDO_USER:-}" ]]; then
  SUDO_HOME=$(eval echo "~${SUDO_USER}")
else
  SUDO_USER="$(logname 2>/dev/null || true)"
  SUDO_HOME=$(eval echo "~${SUDO_USER}")
fi

# 如果默认公钥不存在，尝试 SUDO_USER 的路径
if [[ ! -f "$PUBKEY_PATH" && -n "$SUDO_HOME" && -f "${SUDO_HOME}/.ssh/id_rsa.pub" ]]; then
  PUBKEY_PATH="${SUDO_HOME}/.ssh/id_rsa.pub"
fi

# 交互函数
confirm() {
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    return 0
  fi
  read -rp "$1 [y/N]: " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# 备份/回滚支持
SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/root/init_v2_backups_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

rollback() {
  log "检测到错误，尝试回滚..."
  if [[ -d "$BACKUP_DIR/sshd_config.bak" ]]; then
    cp "$BACKUP_DIR/sshd_config.bak" "$SSH_CONFIG" || true
    log "已恢复 sshd_config"
  fi
  # 恢复 UFW（如果我们创建了规则，简单撤回新端口）
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "${SSH_PORT}"; then
      ufw delete allow "${SSH_PORT}/tcp" || true
      log "已尝试删除 UFW 对新端口的放行"
    fi
  fi
  log "回滚完成。如仍无法连回，请使用控制台或面板修复 /etc/ssh/sshd_config 并重启 ssh 服务。"
  exit 1
}

trap 'rollback' ERR

# -------------------------
log "开始初始化（v2）"
log "备份 sshd_config 到 $BACKUP_DIR"
cp "$SSH_CONFIG" "$BACKUP_DIR/sshd_config.bak"

# 生成随机密码（如果需要）
if [[ "$GENERATE_PASSWORD" == "true" ]]; then
  RANDOM_PASS="$(openssl rand -base64 18)"
else
  RANDOM_PASS=""
fi

# 创建用户（如不存在）
if id "$USERNAME" &>/dev/null; then
  log "用户 $USERNAME 已存在，跳过创建"
else
  log "创建用户 $USERNAME（无密码交互）"
  adduser --disabled-password --gecos "" "$USERNAME"
  if [[ -n "$RANDOM_PASS" ]]; then
    echo "${USERNAME}:${RANDOM_PASS}" | chpasswd
    log "已为 $USERNAME 设置随机密码（已生成）"
  fi
fi

# 配置免密 sudo
log "配置免密 sudo：/etc/sudoers.d/90-$USERNAME"
cat > "/etc/sudoers.d/90-$USERNAME" <<EOF
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 "/etc/sudoers.d/90-$USERNAME"

# 配置用户 .ssh/authorized_keys
USER_HOME=$(eval echo "~$USERNAME")
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

if [[ -f "$PUBKEY_PATH" ]]; then
  log "从 $PUBKEY_PATH 拷贝公钥到 $USERNAME 的 authorized_keys"
  cp "$PUBKEY_PATH" "$USER_HOME/.ssh/authorized_keys"
  chown "$USERNAME:$USERNAME" "$USER_HOME/.ssh/authorized_keys"
  chmod 600 "$USER_HOME/.ssh/authorized_keys"
else
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    log "未找到公钥，且处于非交互模式。跳过公钥配置（请稍后手动添加）。"
  else
    log "未找到公钥，要求你粘贴公钥（一行）并回车："
    read -rp "公钥: " KEY_TEXT
    echo "$KEY_TEXT" > "$USER_HOME/.ssh/authorized_keys"
    chown "$USERNAME:$USERNAME" "$USER_HOME/.ssh/authorized_keys"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
  fi
fi

# -------------------------
# 修改 sshd_config：备份已做，先在副本里编辑并语法检测
TMP_SSH_CONF="$BACKUP_DIR/sshd_config.tmp"
cp "$SSH_CONFIG" "$TMP_SSH_CONF"

# 设置/替换 Port
if grep -qE '^\s*Port\s+' "$TMP_SSH_CONF"; then
  sed -i -r "s/^\s*Port\s+.*/Port ${SSH_PORT}/" "$TMP_SSH_CONF"
else
  echo "Port ${SSH_PORT}" >> "$TMP_SSH_CONF"
fi

# 禁用或保留 root 登录
if [[ "$DISABLE_ROOT_LOGIN" == "true" ]]; then
  if grep -qE '^\s*PermitRootLogin\s+' "$TMP_SSH_CONF"; then
    sed -i -r "s/^\s*PermitRootLogin\s+.*/PermitRootLogin no/" "$TMP_SSH_CONF"
  else
    echo "PermitRootLogin no" >> "$TMP_SSH_CONF"
  fi
fi

# 禁止密码登录（可改）
if [[ "$ENABLE_PASSWORD_LOGIN" == "false" ]]; then
  if grep -qE '^\s*PasswordAuthentication\s+' "$TMP_SSH_CONF"; then
    sed -i -r "s/^\s*PasswordAuthentication\s+.*/PasswordAuthentication no/" "$TMP_SSH_CONF"
  else
    echo "PasswordAuthentication no" >> "$TMP_SSH_CONF"
  fi
fi

# 确保 PubkeyAuthentication yes 存在
if grep -qE '^\s*PubkeyAuthentication\s+' "$TMP_SSH_CONF"; then
  sed -i -r "s/^\s*PubkeyAuthentication\s+.*/PubkeyAuthentication yes/" "$TMP_SSH_CONF"
else
  echo "PubkeyAuthentication yes" >> "$TMP_SSH_CONF"
fi

# 在更换前先语法检查新配置（尽量用 sshd 二进制检测）
log "正在进行 sshd 配置语法检测..."
if command -v sshd >/dev/null 2>&1; then
  if ! sshd -t -f "$TMP_SSH_CONF"; then
    log "新 ssh 配置语法检测失败，停止并回滚"
    rollback
  fi
else
  log "系统不存在 sshd 可执行文件，跳过语法检测（稍后尝试重启服务）。"
fi

# -------------------------
# 防止把自己踢掉的策略：
# 1) 在防火墙打开新端口（如果使用 ufw）
# 2) 将 tmp 配置复制回 /etc/ssh/sshd_config
# 3) 重启 ssh 服务（尝试 ssh -> sshd 两种服务名）
# 4) 如果重启后 ssh 无法启动，则回滚

# UFW 安装与配置（先放行新端口，避免锁死）
if [[ "$USE_UFW" == "true" ]]; then
  if ! command -v ufw >/dev/null 2>&1; then
    log "检测到系统未安装 ufw，正在安装..."
    apt-get update -y
    apt-get install -y ufw
  fi
  # 放行新 SSH 端口、HTTP、HTTPS
  log "放行端口：${SSH_PORT}, 80, 443"
  ufw allow "${SSH_PORT}/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  # 若 ufw 未启用则启用（--force 自动确认）
  if ufw status | grep -q inactive; then
    ufw --force enable
  fi
fi

# 将修改后的配置应用到系统配置文件（已检测过语法）
cp "$TMP_SSH_CONF" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
log "已写入 /etc/ssh/sshd_config（备份保留在 $BACKUP_DIR）"

# 重启 ssh 服务（适配服务名称）
log "尝试重启 SSH 服务（将尝试 'ssh' 与 'sshd' 两种服务名）"
if systemctl list-units --type=service | grep -qE '(^|\s)(ssh|sshd)\.service'; then
  if systemctl restart ssh 2>/dev/null; then
    log "systemctl restart ssh 成功"
  else
    if systemctl restart sshd 2>/dev/null; then
      log "systemctl restart sshd 成功"
    else
      log "尝试使用 systemctl 重启 ssh(s) 失败，尝试使用 service 命令重启"
      if service ssh restart 2>/dev/null; then
        log "service ssh restart 成功"
      elif service sshd restart 2>/dev/null; then
        log "service sshd restart 成功"
      else
        log "所有重启尝试失败，回滚"
        rollback
      fi
    fi
  fi
else
  # 没有找到 systemd 服务条目（非常不常见），尝试直接启动 sshd 可执行文件
  if command -v sshd >/dev/null 2>&1; then
    pkill -f /usr/sbin/sshd || true
    /usr/sbin/sshd -D & sleep 1
    log "尝试以守护进程方式启动 sshd"
  else
    log "未找到 ssh 服务或 sshd 二进制，无法重启 SSH。回滚。"
    rollback
  fi
fi

# 验证 SSH 在新端口监听
if ss -tnlp | grep -q "${SSH_PORT}"; then
  log "SSH 正在监听端口 ${SSH_PORT} ✅"
else
  log "未检测到 SSH 在 ${SSH_PORT} 上监听，回滚"
  rollback
fi

# -------------------------
# 安装 fail2ban（可选）
if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
  log "安装并启用 fail2ban"
  apt-get update -y
  apt-get install -y fail2ban
  systemctl enable --now fail2ban || true
fi

# 输出最终信息
log "初始化完成！以下是登录信息（请妥善保存）："
echo "----------------------------------------"
echo "用户名: $USERNAME"
if [[ -n "$RANDOM_PASS" ]]; then
  echo "初始随机密码: $RANDOM_PASS"
else
  echo "初始随机密码: （未生成）"
fi
echo "SSH 端口: $SSH_PORT"
echo "公钥来源: $PUBKEY_PATH"
echo "免密 sudo: 已启用 (/etc/sudoers.d/90-$USERNAME)"
echo "fail2ban: ${INSTALL_FAIL2BAN}"
echo "ufw: ${USE_UFW}（已尝试放行 ${SSH_PORT}, 80, 443）"
echo "sshd_config 备份: $BACKUP_DIR/sshd_config.bak"
echo "----------------------------------------"

log "注意：如果你处于控制台以外的远程会话，建议先用另一个终端尝试使用新端口登录，确认无误后再关闭当前会话。"

exit 0
