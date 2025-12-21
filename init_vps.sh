#!/bin/bash

# =================================================================
# Script Name: Ubuntu VPS One-Click Initialization
# Description: Setup user, SSH, Sudo, UFW, Fail2ban, and Ports.
# Author: Gemini
# =================================================================

# Color markers for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run this script as root or using sudo.${NC}"
  exit 1
fi

echo -e "${GREEN}=== Ubuntu VPS Initialization Started ===${NC}"

# 1. Configuration Variables (Interactive)
read -p "Enter new username [default: aleta]: " USERNAME
USERNAME=${USERNAME:-aleta}

read -p "Enter custom SSH port [default: 21357]: " SSH_PORT
SSH_PORT=${SSH_PORT:-21357}

# Get Local Public Key
# Note: Since the script runs on the VPS, we ask the user to paste the content of ~/.ssh/id_rsa.pub
echo -e "${YELLOW}Please paste the content of your LOCAL ~/.ssh/id_rsa.pub:${NC}"
read -p "Public Key: " PUBLIC_KEY

if [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Error: Public key is required for secure login.${NC}"
    exit 1
fi

# 2. Generate Random Password
RANDOM_PASS=$(openssl rand -base64 16)

# 3. System Update
echo -e "${YELLOW}Updating system packages...${NC}"
apt update && apt upgrade -y

# 4. Create User and Setup Sudo
echo -e "${YELLOW}Creating user: $USERNAME...${NC}"
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$RANDOM_PASS" | chpasswd
usermod -aG sudo "$USERNAME"

# Enable Passwordless Sudo
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
chmod 0440 "/etc/sudoers.d/$USERNAME"

# 5. Setup SSH Directory and Key
USER_HOME="/home/$USERNAME"
mkdir -p "$USER_HOME/.ssh"
echo "$PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

# 6. Secure SSH Configuration
echo -e "${YELLOW}Configuring SSH on port $SSH_PORT...${NC}"
sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config

# 7. Install Fail2ban
echo -e "${YELLOW}Installing Fail2ban...${NC}"
apt install -y fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF
systemctl restart fail2ban

# 8. Setup UFW Firewall
echo -e "${YELLOW}Configuring UFW Firewall...${NC}"
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

# 9. Restart SSH Service
systemctl restart ssh

# 10. Summary and Completion
echo -e "\n${GREEN}==============================================${NC}"
echo -e "${GREEN}    Initialization Completed Successfully!    ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}Username:   ${NC} $USERNAME"
echo -e "${YELLOW}Password:   ${NC} $RANDOM_PASS (Note: Keep this safe for sudo operations)"
echo -e "${YELLOW}SSH Port:   ${NC} $SSH_PORT"
echo -e "${YELLOW}SSH Command:${NC} ssh -p $SSH_PORT $USERNAME@$(curl -s ifconfig.me)"
echo -e "${YELLOW}Firewall:   ${NC} Ports $SSH_PORT, 80, 443 are OPEN."
echo -e "${GREEN}==============================================${NC}"
echo -e "${RED}Warning: Make sure you can login with the new user before closing this session!${NC}"

