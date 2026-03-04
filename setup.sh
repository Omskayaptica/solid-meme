#!/bin/bash

# ==========================================================================
# СКРИПТ: Xray (VLESS+Reality или VLESS+TLS+Сайт) + Hysteria2 + Security
# Версия 6.0 | Два режима на выбор
# ==========================================================================

# FIX: сначала собираем ввод, потом перезапускаемся внутри screen
if [[ -z "${STY:-}" ]]; then
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              НАСТРОЙКА СЕРВЕРА v6.0                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Выберите режим:"
    echo "  1) VLESS + Reality   — без домена, маскировка под иностранный сайт"
    echo "  2) VLESS + TLS + Сайт — нужен домен и реальный PHP сайт (устойчивее к блокировкам РФ)"
    echo ""
    read -p "Режим [1/2]: " INPUT_MODE

    while [[ "$INPUT_MODE" != "1" && "$INPUT_MODE" != "2" ]]; do
        read -p "Введите 1 или 2: " INPUT_MODE
    done

    read -p "Введите Email для сертификатов: " INPUT_EMAIL

    if [[ "$INPUT_MODE" == "1" ]]; then
        echo ""
        echo "Режим Reality: домен нужен только для Hysteria2."
        read -p "Введите домен (или оставьте пустым чтобы пропустить Hysteria2): " INPUT_DOMAIN
        INPUT_GITHUB=""
        INPUT_SNI="www.google.com"
        read -p "SNI для Reality [www.google.com]: " INPUT_SNI_USER
        [[ -n "$INPUT_SNI_USER" ]] && INPUT_SNI="$INPUT_SNI_USER"
    else
        echo ""
        echo "Режим TLS+Сайт: домен обязателен."
        read -p "Введите домен (example.com): " INPUT_DOMAIN
        while [[ -z "$INPUT_DOMAIN" ]]; do
            read -p "Домен обязателен: " INPUT_DOMAIN
        done
        read -p "GitHub URL репозитория сайта: " INPUT_GITHUB
        while [[ -z "$INPUT_GITHUB" ]]; do
            read -p "GitHub URL обязателен для режима 2: " INPUT_GITHUB
        done
        INPUT_SNI="$INPUT_DOMAIN"

        echo ""
        echo "Настройка .env файла для сайта:"
        read -p "Turnstile Site Key (Enter чтобы пропустить): " INPUT_TURNSTILE_SITE
        read -p "Turnstile Secret Key (Enter чтобы пропустить): " INPUT_TURNSTILE_SECRET
        echo "SMTP настройки:"
        read -p "SMTP Host [smtp.yandex.ru]: " INPUT_SMTP_HOST
        [[ -z "$INPUT_SMTP_HOST" ]] && INPUT_SMTP_HOST="smtp.yandex.ru"
        read -p "SMTP Port [465]: " INPUT_SMTP_PORT
        [[ -z "$INPUT_SMTP_PORT" ]] && INPUT_SMTP_PORT="465"
        read -p "SMTP User (email): " INPUT_SMTP_USER
        read -p "SMTP Password: " INPUT_SMTP_PASS
        read -p "Mail From Email: " INPUT_MAIL_FROM_EMAIL
        read -p "Mail From Name: " INPUT_MAIL_FROM_NAME
    fi

    apt-get install -y screen -q 2>/dev/null || true

    cat > /tmp/setup-vars.sh << EOF
export MODE="${INPUT_MODE}"
export DOMAIN="${INPUT_DOMAIN}"
export EMAIL="${INPUT_EMAIL}"
export GITHUB_REPO_URL="${INPUT_GITHUB}"
export SNI="${INPUT_SNI}"
export TURNSTILE_SITE="${INPUT_TURNSTILE_SITE:-}"
export TURNSTILE_SECRET="${INPUT_TURNSTILE_SECRET:-}"
export SMTP_HOST="${INPUT_SMTP_HOST:-smtp.yandex.ru}"
export SMTP_PORT="${INPUT_SMTP_PORT:-465}"
export SMTP_USER="${INPUT_SMTP_USER:-}"
export SMTP_PASS="${INPUT_SMTP_PASS:-}"
export MAIL_FROM_EMAIL="${INPUT_MAIL_FROM_EMAIL:-}"
export MAIL_FROM_NAME="${INPUT_MAIL_FROM_NAME:-}"
EOF

    echo ""
    echo "Запуск внутри screen..."
    echo "Если соединение оборвётся — переподключитесь и выполните: screen -r server-setup"
    sleep 1
    screen -S server-setup bash -c "source /tmp/setup-vars.sh && bash $0"
    exit 0
fi

# ======================== ВНУТРИ SCREEN ========================

set -euo pipefail
trap 'echo "Ошибка в строке $LINENO. Команда: $BASH_COMMAND"; exit 1' ERR

# --- КОНСТАНТЫ ---
readonly SWAP_SIZE="1G"
readonly PROJECT_DIR="/root/server-setup"
readonly WEBSITE_DIR="${PROJECT_DIR}/website"
readonly BACKUP_DIR="${PROJECT_DIR}/backups/$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="/var/log/server-setup-$(date +%Y%m%d-%H%M%S).log"

HYSTERIA_PORT=8443
XRAY_PORT=443
SKIP_HYSTERIA=false

# Проверяем переменные
[[ -z "${EMAIL:-}" ]] && { echo "❌ EMAIL не задан"; exit 1; }
[[ -z "${MODE:-}" ]]  && { echo "❌ MODE не задан"; exit 1; }

# Если домен не указан в режиме 1 — пропускаем Hysteria2
if [[ -z "${DOMAIN:-}" ]]; then
    SKIP_HYSTERIA=true
fi

# Проверка root
[[ $EUID -ne 0 ]] && { echo "❌ Запустите от root"; exit 1; }

mkdir -p "${PROJECT_DIR}" "$WEBSITE_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "\033[1;32m[$(date '+%Y-%m-%d %H:%M:%S')] ▶ $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*\033[0m"; }
error(){ echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*\033[0m"; exit 1; }

log "=== РЕЖИМ: $([ "$MODE" == "1" ] && echo 'VLESS+Reality' || echo 'VLESS+TLS+Сайт') ==="

# --- 1. ОБНОВЛЕНИЕ СИСТЕМЫ ---
log "1. Обновление системы..."
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y \
    curl git unzip ufw socat htop nano \
    software-properties-common bc jq acl \
    certbot systemd-timesyncd fail2ban \
    docker.io docker-compose

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd 2>/dev/null || true

# --- 2. ОПТИМИЗАЦИИ ---
log "2. Оптимизации ядра и swap..."

add_sysctl() { grep -qF "$1" /etc/sysctl.conf || echo "$1" >> /etc/sysctl.conf; }
add_sysctl "net.core.default_qdisc=fq"
add_sysctl "net.ipv4.tcp_congestion_control=bbr"
add_sysctl "vm.swappiness=10"
add_sysctl "net.core.rmem_max=67108864"
add_sysctl "net.core.wmem_max=67108864"
sysctl -p

if [[ ! -f /swapfile ]]; then
    fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# --- 3. БЕЗОПАСНОСТЬ ---
log "3. Настройка UFW и Fail2ban..."

# FIX: сначала разрешаем SSH чтобы не потерять доступ
ufw allow 22/tcp 2>/dev/null || true
ufw --force reset 2>/dev/null || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'Xray'
ufw allow "${HYSTERIA_PORT}"/udp comment 'Hysteria2'
ufw limit 22/tcp
echo "y" | ufw enable

cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
maxretry = 3
bantime = 3600
findtime = 600
EOF
systemctl enable --now fail2ban 2>/dev/null || true

# --- 4. ПОЛЬЗОВАТЕЛИ ---
log "4. Создание пользователя vpnuser..."
id -u vpnuser &>/dev/null || useradd -r -s /usr/sbin/nologin -M vpnuser
mkdir -p /var/log/xray
chown -R vpnuser:vpnuser /var/log/xray

# --- 5. DOCKER ---
log "5. Настройка Docker..."
systemctl enable --now docker
docker network ls | grep -q webnet || docker network create webnet

# --- 6. SSL СЕРТИФИКАТЫ ---
if [[ -n "${DOMAIN:-}" ]]; then
    log "6. Получение SSL сертификата для ${DOMAIN}..."

    systemctl stop nginx apache2 2>/dev/null || true
    docker stop nginx mysite_nginx 2>/dev/null || true
    sleep 2

    if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
        certbot certonly --standalone --preferred-challenges http \
            -d "${DOMAIN}" --email "${EMAIL}" --agree-tos --non-interactive \
            || error "Не удалось получить сертификат. Проверьте домен и DNS."
    fi

    chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive
    chmod 755 "/etc/letsencrypt/live/${DOMAIN}"
    find "/etc/letsencrypt/archive/${DOMAIN}" -type f -exec chmod 644 {} \;
    setfacl -R -m u:vpnuser:rx /etc/letsencrypt/live
    setfacl -R -m u:vpnuser:rx /etc/letsencrypt/archive
else
    log "6. Домен не указан — пропускаем SSL сертификат"
fi

# --- 7. УСТАНОВКА XRAY ---
log "7. Установка Xray..."

systemctl stop xray 2>/dev/null || true
sleep 2

if [[ ! -f "/usr/local/bin/xray" ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# FIX: генерируем ключи из одного вызова
XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_KEYS=$(/usr/local/bin/xray x25519)
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYS" | awk '/PrivateKey/{print $2}')
XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYS"  | awk '/Password/{print $2}')

# Fallback для старых версий
if [[ -z "$XRAY_PRIVATE_KEY" ]]; then
    XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYS" | awk '/Private/{print $3}')
    XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYS"  | awk '/Public/{print $3}')
fi

[[ -z "$XRAY_PRIVATE_KEY" ]] && error "Не удалось сгенерировать ключи Xray. Вывод: $XRAY_KEYS"

XRAY_SHORT_ID=$(openssl rand -hex 8)

# --- 7а. КОНФИГ XRAY: РЕЖИМ 1 — REALITY ---
if [[ "$MODE" == "1" ]]; then
    log "7а. Настройка Xray в режиме Reality (SNI: ${SNI})..."

    cat > "/usr/local/etc/xray/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${XRAY_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${XRAY_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "${SNI}:443",
        "serverNames": ["${SNI}"],
        "privateKey": "${XRAY_PRIVATE_KEY}",
        "publicKey": "${XRAY_PUBLIC_KEY}",
        "shortIds": ["${XRAY_SHORT_ID}"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF

# --- 7б. КОНФИГ XRAY: РЕЖИМ 2 — TLS + FALLBACK НА САЙТ ---
else
    log "7б. Настройка Xray в режиме TLS+Fallback (домен: ${DOMAIN})..."

    cat > "/usr/local/etc/xray/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": ${XRAY_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${XRAY_UUID}", "flow": "xtls-rprx-vision"}],
      "decryption": "none",
      "fallbacks": [
        {"dest": "127.0.0.1:8080", "xver": 0}
      ]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "serverName": "${DOMAIN}",
        "alpn": ["http/1.1"],
        "certificates": [{
          "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
          "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        }]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
EOF
fi

# Systemd сервис для Xray
cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=vpnuser
Group=vpnuser
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

chown -R vpnuser:vpnuser /usr/local/etc/xray

# FIX: удаляем drop-in файл установщика (User=nobody)
rm -f /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 3
systemctl is-active --quiet xray && log "✅ Xray запущен" || error "❌ Xray не запустился. Логи: $(journalctl -u xray -n 20 --no-pager)"

# --- 8. HYSTERIA2 ---
if [[ "$SKIP_HYSTERIA" == "false" ]]; then
    log "8. Установка и настройка Hysteria2..."

    if [[ ! -f "/usr/local/bin/hysteria" ]]; then
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    HY_PASSWORD=$(openssl rand -base64 16)
    mkdir -p /etc/hysteria

    cat > "/etc/hysteria/config.yaml" << EOF
listen: :${HYSTERIA_PORT}
tls:
  cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem
auth:
  type: password
  password: ${HY_PASSWORD}
masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}/
    rewriteHost: true
    insecure: true
bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

    chown -R vpnuser:vpnuser /etc/hysteria
    chmod 600 /etc/hysteria/config.yaml

    cat > /etc/systemd/system/hysteria-server.service << 'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
User=vpnuser
Group=vpnuser
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    sleep 3
    systemctl is-active --quiet hysteria-server && log "✅ Hysteria2 запущена" || error "❌ Hysteria2 не запустилась. Логи: $(journalctl -u hysteria-server -n 20 --no-pager)"
else
    log "8. Hysteria2 пропущена (домен не указан)"
    HY_PASSWORD=""
fi

# --- 9. САЙТ И NGINX ---
log "9. Деплой сайта..."

if [[ "$MODE" == "2" ]]; then
    # Режим 2: клонируем репо и запускаем через docker-compose на порту 8080
    if [[ -d "$WEBSITE_DIR/.git" ]]; then
        log "Репозиторий уже существует, обновляем..."
        cd "$WEBSITE_DIR" && git pull && cd - >/dev/null
    else
        # FIX: клонируем содержимое прямо в WEBSITE_DIR а не в подпапку
        log "Клонирование репозитория ${GITHUB_REPO_URL}..."
        rm -rf "$WEBSITE_DIR"
        git clone "${GITHUB_REPO_URL}" "$WEBSITE_DIR"
    fi

    if [[ ! -f "${WEBSITE_DIR}/docker-compose.yml" ]]; then
        error "docker-compose.yml не найден в репозитории"
    fi

    # Создаём .env файл из переданных переменных
    log "Создание .env файла..."
    cat > "${WEBSITE_DIR}/.env" << EOF
TURNSTILE_SITE_KEY=${TURNSTILE_SITE:-}
TURNSTILE_SECRET_KEY=${TURNSTILE_SECRET:-}
SMTP_HOST=${SMTP_HOST:-smtp.yandex.ru}
SMTP_PORT=${SMTP_PORT:-465}
SMTP_SECURE=ssl
SMTP_USER=${SMTP_USER:-}
SMTP_PASS=${SMTP_PASS:-}
MAIL_FROM_EMAIL=${MAIL_FROM_EMAIL:-}
MAIL_FROM_NAME=${MAIL_FROM_NAME:-}
EOF
    chmod 600 "${WEBSITE_DIR}/.env"
    log "✅ .env файл создан"

    log "Запуск сайта через docker-compose..."
    cd "$WEBSITE_DIR"
    docker-compose down 2>/dev/null || true
    docker-compose up -d --build --remove-orphans
    cd - >/dev/null

    sleep 5
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080 | grep -qE "^(200|301|302)"; then
        log "✅ Сайт отвечает на порту 8080"
    else
        warn "⚠ Сайт не отвечает на 8080 — проверьте docker-compose logs"
    fi

    # Nginx на порту 80 для HTTP→HTTPS редиректа
    docker stop nginx 2>/dev/null || true
    docker rm nginx 2>/dev/null || true
    mkdir -p /tmp/nginx-redirect
    cat > /tmp/nginx-redirect/redirect.conf << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}
NGINXEOF
    docker run -d --name nginx --restart unless-stopped \
        -p 80:80 \
        -v /tmp/nginx-redirect/redirect.conf:/etc/nginx/conf.d/default.conf:ro \
        nginx:alpine

else
    # Режим 1: простая страница-заглушка
    docker stop nginx 2>/dev/null || true
    docker rm nginx 2>/dev/null || true

    if [[ ! -f "${WEBSITE_DIR}/index.html" ]]; then
        cat > "${WEBSITE_DIR}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>Welcome</title><meta charset="utf-8">
<style>body{font-family:Arial,sans-serif;text-align:center;padding:80px;background:#f5f5f5}
.box{background:white;padding:30px;border-radius:10px;max-width:500px;margin:0 auto;box-shadow:0 2px 10px rgba(0,0,0,.1)}
h1{color:#4CAF50}</style></head>
<body><div class="box"><h1>✅ Server is running</h1><p>Configured successfully.</p></div></body>
</html>
HTMLEOF
    fi

    docker run -d --name nginx --restart unless-stopped \
        --network webnet \
        -p 80:80 \
        -v "${WEBSITE_DIR}:/usr/share/nginx/html:ro" \
        nginx:alpine

    sleep 3
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:80 | grep -qE "^(200|301|302)"; then
        log "✅ Nginx отвечает на порту 80"
    else
        warn "⚠ Nginx не отвечает — проверьте: docker logs nginx"
    fi
fi

# --- 10. АВТООБНОВЛЕНИЕ СЕРТИФИКАТОВ ---
log "10. Настройка автообновления сертификатов..."

cat > /usr/local/bin/update-certs.sh << 'EOF'
#!/bin/bash
set -e
echo "[$(date)] Обновление сертификатов..."
systemctl stop xray hysteria-server 2>/dev/null || true
if certbot renew --quiet --standalone; then
    echo "[$(date)] Сертификаты обновлены"
    systemctl start xray hysteria-server 2>/dev/null || true
    docker restart nginx 2>/dev/null || true
else
    echo "[$(date)] Ошибка обновления" >&2
    systemctl start xray hysteria-server 2>/dev/null || true
    exit 1
fi
EOF

chmod +x /usr/local/bin/update-certs.sh

systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
sleep 1

CRON_JOB="0 3 * * * /usr/local/bin/update-certs.sh"
EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")
if echo "$EXISTING_CRON" | grep -qF "update-certs.sh"; then
    log "Задача cron уже существует"
else
    printf "%s\n%s\n" "$EXISTING_CRON" "$CRON_JOB" | grep -v '^$' | crontab -
    log "✅ Задача cron добавлена"
fi

# --- 11. SSH ---
log "11. SSH — конфиг не меняем автоматически во избежание потери доступа"
warn "Настройте SSH вручную после проверки что всё работает"

# --- 12. ФИНАЛЬНАЯ ПРОВЕРКА И ВЫВОД ---
log "12. Финальная проверка..."
sleep 3

PUBLIC_IP=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                   СТАТУС СЕРВИСОВ                       ║"
echo "╚══════════════════════════════════════════════════════════╝"

check_svc() {
    if systemctl is-active --quiet "$1"; then
        echo -e "  ✅ $1: \033[1;32mACTIVE\033[0m"
    else
        echo -e "  ❌ $1: \033[1;31mFAILED\033[0m"
        journalctl -u "$1" -n 5 --no-pager
    fi
}

check_svc xray
[[ "$SKIP_HYSTERIA" == "false" ]] && check_svc hysteria-server

echo ""
echo "🐳 Docker:"
docker ps --format "  {{.Names}}: {{.Status}} ({{.Ports}})"

echo ""
echo "🔌 Порты:"
ss -tulpn | grep -E ":(80|443|${HYSTERIA_PORT}) " | awk '{print "  " $1, $5}'

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "🌐 IP: ${PUBLIC_IP}  |  Домен: ${DOMAIN:-не указан}  |  Режим: $([ "$MODE" == "1" ] && echo 'Reality' || echo 'TLS+Сайт')"
echo ""

if [[ "$MODE" == "1" ]]; then
    echo "🔐 XRAY VLESS+Reality:"
    echo "   UUID:       ${XRAY_UUID}"
    echo "   Public Key: ${XRAY_PUBLIC_KEY}"
    echo "   Short ID:   ${XRAY_SHORT_ID}"
    echo "   SNI:        ${SNI}"
    echo ""
    echo "━━━━ VLESS ссылка ━━━━"
    echo "vless://${XRAY_UUID}@${PUBLIC_IP}:${XRAY_PORT}?type=tcp&encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}#MyServer-Reality"
    echo ""
    echo "━━━━ NekoBox JSON ━━━━"
    cat << NEKOEOF
{
  "type": "vless",
  "tag": "vless-reality",
  "server": "${PUBLIC_IP}",
  "server_port": ${XRAY_PORT},
  "uuid": "${XRAY_UUID}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": {
      "enabled": true,
      "public_key": "${XRAY_PUBLIC_KEY}",
      "short_id": "${XRAY_SHORT_ID}"
    }
  }
}
NEKOEOF
else
    echo "🔐 XRAY VLESS+TLS+Сайт:"
    echo "   UUID:   ${XRAY_UUID}"
    echo "   Домен:  ${DOMAIN}"
    echo ""
    echo "━━━━ VLESS ссылка ━━━━"
    echo "vless://${XRAY_UUID}@${PUBLIC_IP}:${XRAY_PORT}?type=tcp&encryption=none&flow=xtls-rprx-vision&security=tls&sni=${DOMAIN}&fp=chrome#MyServer-TLS"
    echo ""
    echo "━━━━ NekoBox JSON ━━━━"
    cat << NEKOEOF
{
  "type": "vless",
  "tag": "vless-tls",
  "server": "${PUBLIC_IP}",
  "server_port": ${XRAY_PORT},
  "uuid": "${XRAY_UUID}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}",
    "utls": { "enabled": true, "fingerprint": "chrome" }
  }
}
NEKOEOF
fi

if [[ "$SKIP_HYSTERIA" == "false" ]]; then
    echo ""
    echo "⚡ HYSTERIA2:"
    echo "   Пароль: ${HY_PASSWORD}"
    echo "   Порт:   ${HYSTERIA_PORT}"
    echo ""
    echo "━━━━ VLESS ссылка ━━━━"
    HY_PASSWORD_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${HY_PASSWORD}')")
    echo "hysteria2://${HY_PASSWORD_ENCODED}@${PUBLIC_IP}:${HYSTERIA_PORT}?sni=${DOMAIN}#MyServer-Hysteria2"
    echo ""
    echo "━━━━ NekoBox JSON ━━━━"
    cat << NEKOEOF
{
  "type": "hysteria2",
  "tag": "hysteria2",
  "server": "${PUBLIC_IP}",
  "server_port": ${HYSTERIA_PORT},
  "password": "${HY_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${DOMAIN}"
  }
}
NEKOEOF
fi

echo ""
echo "📋 Лог установки: ${LOG_FILE}"
echo ""
echo -e "\033[1;32m✅ Установка завершена! Сохраните данные выше.\033[0m"
