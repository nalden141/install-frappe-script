#!/bin/bash
# ==============================================================================
# Smart Interactive Frappe/ERPNext Installer (100% Idempotent & Bulletproof)
# Uses 'uv' for Python 3.14, auto-cleans broken runs, and includes 'cron'.
# ==============================================================================

set -e

# ==============================================================================
# ⚙️ DEFAULTS
# ==============================================================================
DEFAULT_BRANCH="version-16"
DEFAULT_SITE="site1.local"
DEFAULT_DB_PASS="admin"
DEFAULT_ADMIN_PASS="admin"
PYTHON_VERSION="python3.14" # Strictly required for Frappe v16+
# ==============================================================================

echo "=========================================================================="
echo "🚀 Smart Frappe/ERPNext Installer"
echo "=========================================================================="
echo "Auto-selected Python: $PYTHON_VERSION (Required for Frappe v16+)"
echo ""
echo "💡 Tip: Just press [Enter] to accept the default values in brackets."
echo ""

# Interactive Prompts with Defaults
read -p "👉 Enter Frappe Branch [${DEFAULT_BRANCH}]: " FRAPPE_BRANCH
FRAPPE_BRANCH=${FRAPPE_BRANCH:-$DEFAULT_BRANCH}

read -p "👉 Enter Site Name [${DEFAULT_SITE}]: " SITE_NAME
SITE_NAME=${SITE_NAME:-$DEFAULT_SITE}

read -s -p "👉 Enter MySQL Root Password [${DEFAULT_DB_PASS}]: " DB_ROOT_PASSWORD
echo ""
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-$DEFAULT_DB_PASS}

read -s -p "👉 Enter Frappe Admin Password [${DEFAULT_ADMIN_PASS}]: " ADMIN_PASSWORD
echo ""
ADMIN_PASSWORD=${ADMIN_PASSWORD:-$DEFAULT_ADMIN_PASS}

echo ""
echo "✅ Configuration saved. Starting installation..."
echo "⚠️  This will take 10-20 minutes. Do not interrupt."
echo "=========================================================================="

# 1. Update System
echo "📦 Step 1: Updating system packages..."
sudo apt update -y && sudo apt upgrade -y

# 1.5 Install uv and Python 3.14 (Bypasses apt limitations)
echo "🐍 Step 1.5: Installing uv and Python 3.14..."
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv python install 3.14

# 2. Install Core Dependencies (ADDED 'cron' to fix Codespace crontab error)
echo "📦 Step 2: Installing core dependencies..."
sudo apt install -y git python3-dev python3-setuptools python3-pip python3-venv \
    software-properties-common xvfb libmysqlclient-dev redis-server curl pkg-config build-essential libfontconfig1 cron

# 3. Install wkhtmltopdf (Workaround for Ubuntu 24.04/26.04)
echo "📦 Step 3: Installing wkhtmltopdf..."
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb || sudo apt --fix-broken install -y
rm -f wkhtmltox_0.12.6.1-2.jammy_amd64.deb

# 4. Install and Secure MariaDB (Bulletproof Container Method)
echo "🗄️  Step 4: Installing and configuring MariaDB..."
sudo apt install -y mariadb-server mariadb-client

echo "   Clearing any hanging MariaDB processes from previous runs..."
sudo pkill -9 mariadbd || true
sudo pkill -9 mysqld || true
sleep 2

sudo mkdir -p /var/run/mysqld
sudo chown -R mysql:mysql /var/run/mysqld

sudo service mariadb stop || true
sleep 2

echo "   Starting MariaDB in safe mode to reset credentials..."
sudo mysqld_safe --skip-grant-tables --skip-networking &
sleep 5

sudo mysql -u root <<EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

echo "   Restarting MariaDB normally..."
sudo pkill -9 mysqld || true
sudo pkill -9 mariadbd || true
sleep 2

sudo service mariadb start
sleep 3

echo "   Configuring MariaDB character sets..."
sudo tee -a /etc/mysql/my.cnf > /dev/null <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
sudo service mariadb restart
sleep 2

# 5. Install Node.js 24 and Yarn via NVM (Codespace Compatible)
echo "🟢 Step 5: Installing Node.js 24 and Yarn..."

if [ -s "/usr/local/share/nvm/nvm.sh" ]; then
    export NVM_DIR="/usr/local/share/nvm"
    \. "$NVM_DIR/nvm.sh"
elif [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    \. "$NVM_DIR/nvm.sh"
else
    echo "   Installing NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
fi

echo "   Installing Node.js 24..."
nvm install 24
nvm use 24

echo "   Ensuring Yarn is installed..."
npm install -g yarn --force || true

# 6. Install Frappe Bench
echo "🛠️  Step 6: Installing Frappe Bench..."
pip3 install frappe-bench --break-system-packages

# Ensure PATH is permanently added to .bashrc
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi

# 7. Initialize Frappe Bench (Idempotent Cleanup)
echo "🏗️  Step 7: Initializing Frappe Bench (this may take a few minutes)..."

# Go to home directory and clean up any broken previous attempts
cd ~
if [ -d "frappe-bench" ]; then
    echo "   Cleaning up previous broken bench installation..."
    rm -rf frappe-bench
fi

bench init frappe-bench --frappe-branch ${FRAPPE_BRANCH} --python ${PYTHON_VERSION}
cd frappe-bench

# 8. Create New Site
echo "🌐 Step 8: Creating new site '${SITE_NAME}'..."
bench new-site ${SITE_NAME} --mariadb-root-password "${DB_ROOT_PASSWORD}" --admin-password "${ADMIN_PASSWORD}"

# 9. Install ERPNext and HRMS
echo "📥 Step 9: Downloading and installing ERPNext and HRMS..."
bench get-app --branch ${FRAPPE_BRANCH} erpnext
bench get-app --branch ${FRAPPE_BRANCH} hrms

bench --site ${SITE_NAME} install-app erpnext
bench --site ${SITE_NAME} install-app hrms

# 10. Final Configuration
echo "⚙️  Step 10: Configuring site..."
bench use ${SITE_NAME}
bench --site ${SITE_NAME} enable-scheduler
bench --site ${SITE_NAME} set-maintenance-mode off
bench set-config -g developer_mode true
bench --site ${SITE_NAME} set-config server_script_enabled true

echo "=========================================================================="
echo "✅ INSTALLATION COMPLETE!"
echo "=========================================================================="
echo "👉 To start the server, run:"
echo "   cd ~/frappe-bench"
echo "   bench start"
echo ""
echo "👉 Then open your browser and go to:"
echo "   http://${SITE_NAME}:8000  (or http://localhost:8000)"
echo ""
echo "🔑 Login Credentials:"
echo "   Username: Administrator"
echo "   Password: ${ADMIN_PASSWORD}"
echo "=========================================================================="
