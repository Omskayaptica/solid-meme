#!/bin/bash

# ==========================================================================
# Скрипт автоматической настройки сервера (VPN + Docker Website + Security)
# ==========================================================================

# Строгий режим
set -euo pipefail
trap 'echo "Ошибка в строке $LINENO. Скрипт прерван."; exit 1' ERR

# --- ИНТЕРАКТИВНЫЕ НАСТРОЙКИ ---
echo "--- Настройка параметров сервера ---"
read -p "Введите домен (например, example.com): " DOMAIN
read -p "Введите ваш Email для SSL (например, admin@gmail.com): " EMAIL
read -p "Введите URL репозитория с сайтом (GitHub): " GITHUB_REPO_URL

# Константы
HYSTERIA_PORT=443
SWAP_SIZE="1G"
PROJECT_DIR="/root/server-setup"
CONFIG_DIR="${PROJECT_DIR}/configs"
WEBSITE_DIR="${PROJECT_DIR}/website"

# Создание необходимых директорий
mkdir -p "$CONFIG_DIR" "$WEBSITE_DIR"

# Журналирование
LOG_FILE="/var/log/server-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- ФУНКЦИИ-ПОМОЩНИКИ ---
log() { echo -e "\033[1;32m[$(date '+%Y-%m-%d %H:%M:%S')] $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ $*\033[0m"; }
error() { echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $*\033[0m"; exit 1; }

# Функция для добавления строк в sysctl без дубликатов (Идемпотентность)
add_sysctl() {
    local key_val="$1"
    grep -qF "$key_val" /etc/sysctl.conf || echo "$key_val" >> /etc/sysctl.conf
}

add_cron_if_not_exists() {
    local job="$1"
    (crontab -l 2>/dev/null | grep -F "$job") >/dev/null || (crontab -l 2>/dev/null; echo "$job") | crontab -
}

# Проверка root
if [ "$EUID" -ne 0 ]; then error "Запустите скрипт от root"; fi

log "=== НАЧАЛО УСТАНОВКИ ==="

# --- 1. ОБНОВЛЕНИЕ И ЗАВИСИМОСТИ ---
log "Обновление системы и установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y curl git unzip ufw socat htop nano cron \
    software-properties-common bc jq yamllint acl systemd-timesyncd

# Настройка времени
timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd

# --- 2. СИСТЕМНЫЕ ОПТИМИЗАЦИИ ---
log "Настройка BBR и Swap..."
add_sysctl "net.core.default_qdisc=fq"
add_sysctl "net.ipv4.tcp_congestion_control=bbr"
add_sysctl "vm.swappiness=10"
add_sysctl "vm.vfs_cache_pressure=50"
sysctl -p

# Swap (Проверка существования)
if [ ! -f /swapfile ]; then
    log "Создание swap файла..."
    fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile && swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# --- 3. БЕЗОПАСНОСТЬ (UFW) ---
log "Настройка фаервола UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP (Certbot/Web)'
ufw allow 443/tcp comment 'HTTPS (Web/Xray)'
ufw allow "$HYSTERIA_PORT"/udp comment 'Hysteria2'
ufw limit 22/tcp comment 'SSH-protection'
ufw --force enable

# Создание пользователя для VPN
if ! id -u vpnuser >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -M vpnuser
fi

# --- 4. SSL СЕРТИФИКАТЫ ---
log "Настройка SSL (Certbot)..."
apt-get install -y certbot

if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    # Останавливаем всё, что может занимать 80 порт перед получением
    systemctl stop nginx docker 2>/dev/null || true
    certbot certonly --standalone --preferred-challenges http \
        -d "${DOMAIN}" --email "${EMAIL}" --agree-tos --non-interactive
fi

# Права доступа для vpnuser
setfacl -R -m u:vpnuser:rx /etc/letsencrypt/live
setfacl -R -m u:vpnuser:rx /etc/letsencrypt/archive

# ФИКС ОБНОВЛЕНИЯ: Pre/Post hooks для освобождения 80 порта
RENEW_HOOK="systemctl stop xray hysteria-server; [ -f ${WEBSITE_DIR}/docker-compose.yml ] && docker compose -f ${WEBSITE_DIR}/docker-compose.yml stop"
POST_HOOK="systemctl start xray hysteria-server; [ -f ${WEBSITE_DIR}/docker-compose.yml ] && docker compose -f ${WEBSITE_DIR}/docker-compose.yml start"

add_cron_if_not_exists "0 3 * * * /usr/bin/certbot renew --quiet --pre-hook \"$RENEW_HOOK\" --post-hook \"$POST_HOOK\""

# --- 5. УСТАНОВКА VPN (Xray & Hysteria2) ---
log "Установка VPN..."
[ ! -f "/usr/local/bin/xray" ] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
[ ! -f "/usr/local/bin/hysteria" ] && bash <(curl -fsSL https://get.hy2.sh/)

# Генерация пароля, если его нет
HY_PASSWORD=$(openssl rand -base64 16)

# Создание конфига Hysteria2 (с исправленным портом и маскировкой)
cat > "${CONFIG_DIR}/hysteria.yaml" << EOF
listen: :$HYSTERIA_PORT
tls:
  cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem
auth:
  type: password
  password: $HY_PASSWORD
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:80/  # Направляем на твой сайт в Docker
    rewriteHost: true
EOF

mkdir -p /etc/hysteria
cp "${CONFIG_DIR}/hysteria.yaml" /etc/hysteria/config.yaml
chown -R vpnuser:vpnuser /etc/hysteria
chmod 600 /etc/hysteria/config.yaml

# Systemd сервис
cat > /etc/systemd/system/hysteria-server.service << 'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
User=vpnuser
Group=vpnuser
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria-server

# --- 6. УСТАНОВКА DOCKER & WEBSITE ---
log "Настройка Docker и сайта..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh && rm get-docker.sh
fi

if [ -n "$GITHUB_REPO_URL" ]; then
    if [ -d "$WEBSITE_DIR/.git" ]; then
        log "Сайт уже существует, обновляем..."
        cd "$WEBSITE_DIR" && git pull && cd -
    else
        git clone "$GITHUB_REPO_URL" "$WEBSITE_DIR"
    fi
    
    if [ -f "${WEBSITE_DIR}/docker-compose.yml" ]; then
        cd "$WEBSITE_DIR"
        docker compose up -d --build
        cd -
    fi
fi

# --- 7. HARDENING SSH (Безопасный подход) ---
log "Усиление защиты SSH..."
# ПРОВЕРКА КЛЮЧЕЙ (чтобы не заблокировать себя)
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    log "SSH ключи найдены. Отключаем вход по паролю."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    if sshd -t; then
        systemctl restart ssh
    else
        warn "Ошибка конфига SSH. Откат."
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    fi
else
    warn "SSH КЛЮЧИ НЕ НАЙДЕНЫ! Вход по паролю оставлен ВКЛЮЧЕННЫМ."
fi

# --- 8. ФИНАЛ ---
PUBLIC_IP=$(curl -s -4 ifconfig.co || echo "не определён")

log "=========================================="
log "   НАСТРОЙКА ЗАВЕРШЕНА! 🚀"
log "   IP сервера: $PUBLIC_IP"
log "   Домен: $DOMAIN"
log "   Hysteria Порт: $HYSTERIA_PORT (UDP)"
log "   Hysteria Пароль: $HY_PASSWORD"
log "=========================================="
