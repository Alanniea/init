#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# Ubuntu 一键初始化脚本
# 功能：
# - 创建用户 aleta（若不存在）
# - 随机密码并显示/保存
# - 将公钥 (~/.ssh/id_rsa.pub) 写入 /home/aleta/.ssh/authorized_keys（若不存在会要求你粘贴）
# - 将 aleta 加入 sudo 并启用免密 sudo
# - 修改 SSH 端口为 21357（备份原配置）
# - 安装 fail2ban、ufw，放行 80/443 和 新 SSH 端口
# - 交互式确认（关键操作）
# -----------------------

USER_NAME="aleta"
SSH_PORT="21357"
DEFAULT_PUBKEY_PATH="~/.ssh/id_rsa.pub"
PASS_FILE="/root/${USER_NAME}-password.txt"
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/root/init-backups-$(date +%Y%m%d%H%M%S)"

echo "Ubuntu VPS 初始化脚本 — 将配置用户: ${USER_NAME}, SSH 端口: ${SSH_PORT}"
echo

# require root
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行此脚本（sudo）。"
  exit 1
fi

read -p "继续执行并修改系统配置吗？（y/N） " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "已取消。"
  exit 0
fi

# create backup dir
mkdir -p "${BACKUP_DIR}"
echo "备份目录：${BACKUP_DIR}"

# Generate random password (12 chars, reasonably strong)
PASSWORD="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)"
# Ensure a deterministic fallback
if [[ -z "${PASSWORD:-}" ]]; then
  PASSWORD="$(date +%s | sha256sum | base64 | head -c 16)"
fi

echo "准备创建用户 ${USER_NAME}（若已存在会尝试保留原配置并更新授权密钥与 sudo 权限）"

if id -u "${USER_NAME}" >/dev/null 2>&1; then
  echo "用户 ${USER_NAME} 已存在，跳过创建步骤。"
else
  # create user with home and bash
  useradd -m -s /bin/bash "${USER_NAME}"
  echo "${USER_NAME} 创建完成。"
fi

# Set the password for the user
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "已为 ${USER_NAME} 设置随机密码。"

# Save password to file (restricted)
echo "用户名: ${USER_NAME}" > "${PASS_FILE}"
echo "密码: ${PASSWORD}" >> "${PASS_FILE}"
chmod 600 "${PASS_FILE}"
echo "密码已保存到 ${PASS_FILE}（仅 root 可读）。"

# Setup .ssh and authorized_keys
read -p "公钥文件路径（默认：${DEFAULT_PUBKEY_PATH}）。如果服务器上不存在该文件，会提示你粘贴公钥。回车使用默认： " -r PUBKEY_INPUT
PUBKEY_INPUT="${PUBKEY_INPUT:-${DEFAULT_PUBKEY_PATH}}"
# expand ~ if present
PUBKEY_PATH="$(eval echo "${PUBKEY_INPUT}")"

USER_SSH_DIR="/home/${USER_NAME}/.ssh"
AUTH_KEYS="${USER_SSH_DIR}/authorized_keys"

mkdir -p "${USER_SSH_DIR}"
chmod 700 "${USER_SSH_DIR}"

if [[ -f "${PUBKEY_PATH}" ]]; then
  echo "找到公钥文件：${PUBKEY_PATH}，将其写入 ${AUTH_KEYS}"
  cat "${PUBKEY_PATH}" >> "${AUTH_KEYS}"
else
  echo "未在 ${PUBKEY_PATH} 找到公钥。请在下一行粘贴你的公钥（单行，开头通常为 ssh-rsa 或 ssh-ed25519），粘贴完成后按回车："
  read -r PASTED_KEY
  if [[ -z "${PASTED_KEY// /}" ]]; then
    echo "未提供公钥，跳过写入 authorized_keys（此时请通过密码登录或手动上传公钥）。"
  else
    echo "${PASTED_KEY}" >> "${AUTH_KEYS}"
  fi
fi

chmod 600 "${AUTH_KEYS}" || true
chown -R "${USER_NAME}:${USER_NAME}" "${USER_SSH_DIR}"
echo "已配置 ${USER_NAME} 的 authorized_keys（若有）。"

# Configure passwordless sudo for this user
SUDO_FILE="/etc/sudoers.d/${USER_NAME}"
echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "${SUDO_FILE}"
chmod 440 "${SUDO_FILE}"
echo "已为 ${USER_NAME} 启用免密 sudo（文件：${SUDO_FILE}）。"

# Install packages: fail2ban, ufw, openssh-server (if missing)
echo "更新 apt 并安装 fail2ban、ufw（可能需要一些时间）..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban ufw openssh-server

# Backup sshd_config before modifying
mkdir -p "${BACKUP_DIR}/etc-ssh"
cp -a "${SSHD_CONFIG}" "${BACKUP_DIR}/etc-ssh/sshd_config.bak"
echo "已备份 ${SSHD_CONFIG} 到 ${BACKUP_DIR}/etc-ssh/sshd_config.bak"

# Modify SSH port (and ensure PubkeyAuthentication on)
# Use awk/sed to change or append settings
# Port
if grep -Eiq "^Port[[:space:]]+" "${SSHD_CONFIG}"; then
  sed -ri "s/^(#?)[[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/I" "${SSHD_CONFIG}"
else
  echo "Port ${SSH_PORT}" >> "${SSHD_CONFIG}"
fi

# Ensure PubkeyAuthentication yes
if grep -Eiq "^PubkeyAuthentication[[:space:]]+" "${SSHD_CONFIG}"; then
  sed -ri "s/^(#?)[[:space:]]*PubkeyAuthentication[[:space:]]+.*/PubkeyAuthentication yes/I" "${SSHD_CONFIG}"
else
  echo "PubkeyAuthentication yes" >> "${SSHD_CONFIG}"
fi

# Ensure AuthorizedKeysFile exists (default usually .ssh/authorized_keys)
if ! grep -Eiq "^AuthorizedKeysFile[[:space:]]+" "${SSHD_CONFIG}"; then
  echo "AuthorizedKeysFile %h/.ssh/authorized_keys" >> "${SSHD_CONFIG}"
fi

# (可选) 不强制更改 PasswordAuthentication，这里保持系统默认以免锁住访问
echo "SSHD 配置已更新：Port ${SSH_PORT}，启用公钥认证（已备份原配置）。"

# Restart ssh service
if systemctl restart ssh 2>/dev/null; then
  echo "ssh 服务已重启（systemctl）。"
else
  service ssh restart || true
  echo "尝试使用 init 脚本重启 ssh。"
fi

# Configure UFW: allow new SSH port, 80, 443
echo "配置防火墙（ufw）：放行 ${SSH_PORT}, 80, 443。注意：启用 ufw 有可能影响当前连接。"
read -p "确认现在允许并启用 ufw 吗？（y/N） " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
  ufw allow "${SSH_PORT}"/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  echo "ufw 已启用并放行端口：${SSH_PORT},80,443。"
else
  echo "跳过启用 ufw。已为这些端口添加规则（若你手动启用 ufw 会生效）。"
  ufw allow "${SSH_PORT}"/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi

# Basic fail2ban: ensure service running
systemctl enable --now fail2ban || true
echo "fail2ban 已启用并启动。"

# Final summary
echo
echo "========================================"
echo "初始化完成（部分操作可能需要几秒钟生效）。"
echo "用户: ${USER_NAME}"
echo "SSH 端口: ${SSH_PORT}"
echo "随机密码已保存到: ${PASS_FILE}"
echo
echo "提示："
echo "- 若你是通过 SSH 连接并且当前使用的是旧的 SSH 端口，请在本地打开一个新的终端先测试新端口是否可连通："
echo "    ssh -p ${SSH_PORT} ${USER_NAME}@<your-server-ip>"
echo "- 如果公钥未正确添加，你仍然可以使用随机密码登录（前提是 PasswordAuthentication 仍为 yes）。"
echo "- sshd 原配置已备份到 ${BACKUP_DIR}"
echo "- 若需要禁用 root 登录或禁止密码认证，请在确认公钥生效后手动修改 ${SSHD_CONFIG}（或告诉我我可帮你修改）"
echo "========================================"
