#!/usr/bin/env bash
set -euo pipefail

# ===== 配置默认值（可在交互过程中修改） =====
USERNAME="aleta"
SSH_PORT="21357"
PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"
ALLOW_SSH_PASSWORD="no"   # 默认不允许密码登录（交互里可改）
GENERATED_PW_LEN=16

# ===== 颜色输出（可选） =====
green() { printf "\\033[1;32m%s\\033[0m\n" "$*"; }
red()   { printf "\\033[1;31m%s\\033[0m\n" "$*"; }
info()  { printf "\\033[1;34m%s\\033[0m\n" "$*"; }

# ===== 检查 root =====
if [ "$(id -u)" -ne 0 ]; then
  red "请以 root 用户或通过 sudo 运行此脚本：sudo bash $0"
  exit 1
fi

info "开始 Ubuntu 初始化脚本 — 用户: ${USERNAME}, SSH 端口: ${SSH_PORT}"

read -r -p "确认要继续执行脚本并对系统做修改吗？(yes/NO): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  red "已取消。"
  exit 1
fi

# 交互：是否修改默认公钥路径
read -r -p "公钥文件路径（回车使用 ${PUBKEY_PATH}）: " TMP
if [ -n "${TMP}" ]; then PUBKEY_PATH="${TMP}"; fi

# 交互：是否修改 SSH 端口
read -r -p "SSH 端口（回车使用 ${SSH_PORT}）: " TMP
if [ -n "${TMP}" ]; then SSH_PORT="${TMP}"; fi

# 交互：是否允许 SSH 密码登录（默认不允许）
read -r -p "是否允许 SSH 密码登录？(y/N): " TMP
if [[ "${TMP,,}" == "y" || "${TMP,,}" == "yes" ]]; then
  ALLOW_SSH_PASSWORD="yes"
else
  ALLOW_SSH_PASSWORD="no"
fi

# 交互：如果用户已存在，询问如何处理
if id "${USERNAME}" >/dev/null 2>&1; then
  read -r -p "用户 ${USERNAME} 已存在。您要覆盖密码/authorized_keys并确保无密码 sudo 吗？(yes/NO): " ACTION
  if [[ "${ACTION}" != "yes" ]]; then
    red "未覆盖已存在用户，脚本退出。"
    exit 1
  fi
fi

info "更新 apt 并安装必要软件包..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends openssh-server sudo ufw fail2ban ca-certificates

# 创建用户（如果不存在）
if ! id "${USERNAME}" >/dev/null 2>&1; then
  info "创建用户 ${USERNAME}..."
  useradd -m -s /bin/bash "${USERNAME}"
else
  info "用户 ${USERNAME} 已存在，跳过创建步骤。"
fi

# 生成随机密码
PW=$(openssl rand -base64 48 | tr -d /=+ | cut -c1-"${GENERATED_PW_LEN}")
info "为用户 ${USERNAME} 设置随机密码..."
echo "${USERNAME}:${PW}" | chpasswd

# 启用无密码 sudo
info "配置无密码 sudo..."
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 440 "/etc/sudoers.d/${USERNAME}"

# 配置用户的 authorized_keys
if [ -f "${PUBKEY_PATH}" ]; then
  info "将公钥 ${PUBKEY_PATH} 写入 /home/${USERNAME}/.ssh/authorized_keys ..."
  su - "${USERNAME}" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  cp "${PUBKEY_PATH}" "/home/${USERNAME}/.ssh/authorized_keys"
  chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh/authorized_keys"
  chmod 600 "/home/${USERNAME}/.ssh/authorized_keys"
else
  red "找不到公钥文件：${PUBKEY_PATH}"
  read -r -p "是否在以后手动添加公钥并继续？(yes/NO): " PKCONF
  if [[ "${PKCONF}" != "yes" ]]; then
    red "请先把公钥上传到服务器再运行脚本。退出。"
    exit 1
  fi
fi

# 备份 sshd_config
SSHD_CONF="/etc/ssh/sshd_config"
cp -n "${SSHD_CONF}" "${SSHD_CONF}.bak.$(date +%s)" || true

info "修改 SSH 配置（端口: ${SSH_PORT}，密码登录: ${ALLOW_SSH_PASSWORD}）..."
# 注释掉已有的 Port 配置并添加新的 Port 行（更稳妥）
sed -i 's/^[[:space:]]*Port[[:space:]]\+[0-9]\+/ # &/' "${SSHD_CONF}" || true
# 添加 Port 指令（如果已存在相同的，不会重复）
grep -q -E "^Port ${SSH_PORT}$" "${SSHD_CONF}" || echo "Port ${SSH_PORT}" >> "${SSHD_CONF}"

# 确保 PubkeyAuthentication yes
sed -i 's/^[#[:space:]]*PubkeyAuthentication.*/PubkeyAuthentication yes/' "${SSHD_CONF}" || echo "PubkeyAuthentication yes" >> "${SSHD_CONF}"

# 依据选择设置 PasswordAuthentication
if [ "${ALLOW_SSH_PASSWORD}" = "yes" ]; then
  sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "${SSHD_CONF}" || echo "PasswordAuthentication yes" >> "${SSHD_CONF}"
else
  sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "${SSHD_CONF}" || echo "PasswordAuthentication no" >> "${SSHD_CONF}"
fi

# 确保 PermitRootLogin 不被意外启用为 yes（仅提示，不强制更改）
grep -q '^PermitRootLogin' "${SSHD_CONF}" || echo "PermitRootLogin prohibit-password" >> "${SSHD_CONF}"

# 重启 ssh 服务（提示用户注意断连风险）
info "准备重启 ssh 服务。注意：如果你当前依赖此会话，修改 SSH 端口或禁用密码会断开连接。"
read -r -p "现在重启 ssh 服务以应用更改？(yes/NO): " RESTARTSSH
if [[ "${RESTARTSSH}" == "yes" ]]; then
  systemctl restart sshd || systemctl restart ssh || true
  info "sshd 已重启。"
else
  info "已跳过重启。请手动运行：systemctl restart sshd"
fi

# 配置 UFW（防火墙）
info "配置 UFW：允许 -- SSH(${SSH_PORT}), HTTP(80), HTTPS(443) ..."
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp

# 启用 UFW（如果尚未启用）
if ufw status | grep -qi inactive; then
  info "启用 UFW..."
  ufw --force enable
else
  info "UFW 已启用，规则已添加。"
fi

# 安装并确保 fail2ban 启动
info "启用并重启 fail2ban..."
systemctl enable --now fail2ban || true

# 最后输出信息
green "==== 初始化完成 ===="
cat <<EOF
用户: ${USERNAME}
随机密码: ${PW}
SSH 端口: ${SSH_PORT}
公钥路径: ${PUBKEY_PATH}
无密码 sudo: 已启用 (/${USERNAME} -> NOPASSWD)
fail2ban: 已安装并启动
防火墙 (ufw): 已放行 80, 443, ${SSH_PORT}

重要提醒：
- 如果你在本地使用公钥登录，请从本地用：
  ssh -p ${SSH_PORT} ${USERNAME}@<你的服务器IP>
- 如果你禁用了密码登录（PasswordAuthentication no），请先确保公钥已经正确写入 /home/${USERNAME}/.ssh/authorized_keys，否则可能无法登录。
- sshd 配置备份： ${SSHD_CONF}.bak.*
EOF

green "脚本运行结束。"
