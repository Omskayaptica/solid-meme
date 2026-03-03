#!/bin/bash

# ==========================================================================
# СКРИПТ: Docker Website + Xray (VLESS+Reality) + Hysteria2 + Security
# Версия 5.1 | Исправлены все баги
# ==========================================================================

# FIX: сначала собираем ввод, потом перезапускаемся внутри screen
if [[ -z "${STY:-}" ]]; then
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           НАСТРОЙКА СЕРВЕРА v5.1 (РАБОТАЕТ СРАЗУ)       ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    read -p "Введите домен (example.com): " INPUT_DOMAIN
    read -p "Введите Email для сертификатов: " INPUT_EMAIL
    read -p "GitHub URL сайта (оставьте пустым, если не нужно): " INPUT_GITHUB

    apt-get install -y screen -q 2>/dev/null || true

    # Записываем переменные во временный файл
    cat > /tmp/setup-vars.sh << EOF
export DOMAIN="${INPUT_DOMAIN}"
export EMAIL="${INPUT_EMAIL}"
export GITHUB_REPO_URL="${INPUT_GITHUB}"
EOF

    echo ""
    echo "Запуск внутри screen..."
    echo "Если соединение оборвётся — переподключитесь и выполните: screen -r server-setup"
    sleep 1
    screen -S server-setup bash -c "source /tmp/setup-vars.sh && bash $0"
    exit 0
fi

set -euo pipefail
trap 'echo "Ошибка в строке $LINENO. Команда: $BASH_COMMAND"; exit 1' ERR

# --- КОНСТАНТЫ ---
readonly SWAP_SIZE="1G"
readonly PROJECT_DIR="/root/server-setup"
readonly CONFIG_DIR="${PROJECT_DIR}/configs"
readonly WEBSITE_DIR="${PROJECT_DIR}/website"
readonly BACKUP_DIR="${PROJECT_DIR}/backups/$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="/var/log/server-setup-$(date +%Y%m%d-%H%M%S).log"

# --- ПАРАМЕТРЫ (переданы через env от screen) ---
# Проверяем что переменные переданы
[[ -z "${DOMAIN:-}" ]] && { echo "❌ DOMAIN не задан"; exit 1; }
[[ -z "${EMAIL:-}" ]] && { echo "❌ EMAIL не задан"; exit 1; }
GITHUB_REPO_URL="${GITHUB_REPO_URL:-}"

HYSTERIA_PORT=8443
XRAY_PORT=443

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Запустите скрипт от root" >&2
    exit 1
fi

mkdir -p "$CONFIG_DIR" "$WEBSITE_DIR" "$BACKUP_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "\033[1;32m[$(date '+%Y-%m-%d %H:%M:%S')] ▶ $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*\033[0m"; }
error(){ echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*\033[0m"; exit 1; }

backup_config() {
    local file="$1"
    [[ -f "$file" ]] && cp "$file" "${BACKUP_DIR}/$(basename "$file").bak-$(date +%s)"
}

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

# --- 2. СИСТЕМНЫЕ ОПТИМИЗАЦИИ ---
log "2. Оптимизации ядра и swap..."

add_sysctl() {
    grep -qF "$1" /etc/sysctl.conf || echo "$1" >> /etc/sysctl.conf
}
add_sysctl "net.core.default_qdisc=fq"
add_sysctl "net.ipv4.tcp_congestion_control=bbr"
add_sysctl "vm.swappiness=10"
add_sysctl "net.core.rmem_max=67108864"
add_sysctl "net.core.wmem_max=67108864"
sysctl -p

if [[ ! -f /swapfile ]]; then
    fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# --- 3. БЕЗОПАСНОСТЬ ---
log "3. Настройка UFW и Fail2ban..."

# FIX: сначала разрешаем SSH, потом сбрасываем и настраиваем заново
# чтобы не потерять доступ если скрипт упадёт в середине
ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
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

# --- 4. ПОЛЬЗОВАТЕЛИ И ПРАВА ---
log "4. Создание пользователя vpnuser..."
id -u vpnuser &>/dev/null || useradd -r -s /usr/sbin/nologin -M vpnuser
mkdir -p /var/log/xray
chown -R vpnuser:vpnuser /var/log/xray

# --- 5. DOCKER ---
log "5. Настройка Docker..."
systemctl enable --now docker
docker network ls | grep -q webnet || docker network create webnet

# --- 6. SSL СЕРТИФИКАТЫ ---
log "6. Получение SSL сертификатов..."

# Останавливаем всё что может занимать порт 80
systemctl stop nginx apache2 2>/dev/null || true
docker stop nginx 2>/dev/null || true
sleep 2

if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    certbot certonly --standalone --preferred-challenges http \
        -d "${DOMAIN}" --email "${EMAIL}" --agree-tos --non-interactive \
        || error "Не удалось получить сертификат. Проверьте домен и DNS."
fi

# Права на сертификаты
chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive
chmod 755 "/etc/letsencrypt/live/${DOMAIN}"
find "/etc/letsencrypt/archive/${DOMAIN}" -type f -exec chmod 644 {} \;
setfacl -R -m u:vpnuser:rx /etc/letsencrypt/live
setfacl -R -m u:vpnuser:rx /etc/letsencrypt/archive

# --- 7. XRAY ---
log "7. Установка и настройка Xray..."

systemctl stop xray 2>/dev/null || true
sleep 2

if [[ ! -f "/usr/local/bin/xray" ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# FIX: генерируем ключи из ОДНОГО вызова
XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
XRAY_KEYS=$(/usr/local/bin/xray x25519)

# FIX: формат вывода новых версий Xray: PrivateKey / Password (это публичный ключ)
XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYS" | awk '/PrivateKey/{print $2}')
XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYS"  | awk '/Password/{print $2}')

# Fallback для старых версий с форматом "Private key" / "Public key"
if [[ -z "$XRAY_PRIVATE_KEY" ]]; then
    XRAY_PRIVATE_KEY=$(echo "$XRAY_KEYS" | awk '/Private/{print $3}')
    XRAY_PUBLIC_KEY=$(echo "$XRAY_KEYS"  | awk '/Public/{print $3}')
fi

[[ -z "$XRAY_PRIVATE_KEY" ]] && error "Не удалось сгенерировать ключи Xray. Вывод: $XRAY_KEYS"

XRAY_SHORT_ID=$(openssl rand -hex 8)

log "Xray ключи сгенерированы:"
log "  Private: ${XRAY_PRIVATE_KEY:0:10}..."
log "  Public:  ${XRAY_PUBLIC_KEY:0:10}..."

backup_config "/usr/local/etc/xray/config.json"

cat > "/usr/local/etc/xray/config.json" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": ${XRAY_PORT},
    "protocol": "vless",
    "tag": "vless-in",
    "settings": {
      "clients": [{
        "id": "${XRAY_UUID}",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.google.com:443",
        "serverNames": ["www.google.com", "${DOMAIN}"],
        "privateKey": "${XRAY_PRIVATE_KEY}",
        "publicKey": "${XRAY_PUBLIC_KEY}",
        "shortIds": ["${XRAY_SHORT_ID}"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"]
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "tag": "direct"
  }, {
    "protocol": "blackhole",
    "tag": "blocked"
  }]
}
EOF

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

# FIX: установщик Xray создаёт drop-in файл который переопределяет User=nobody
# из-за этого Xray не может биндить порт 443 — удаляем его
rm -f /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 3
systemctl is-active --quiet xray && log "✅ Xray запущен" || error "❌ Xray не запустился. Логи: $(journalctl -u xray -n 20 --no-pager)"

# --- 8. HYSTERIA2 ---
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
    url: http://127.0.0.1:80/
    rewriteHost: true
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

# --- 9. NGINX + САЙТ ---
log "9. Деплой сайта и запуск Nginx..."

if [[ -n "$GITHUB_REPO_URL" ]]; then
    if [[ -d "$WEBSITE_DIR/.git" ]]; then
        cd "$WEBSITE_DIR" && git pull && cd - >/dev/null
    else
        git clone "$GITHUB_REPO_URL" "$WEBSITE_DIR"
    fi
fi

# Создаём страницу по умолчанию если нет index.html
if [[ ! -f "${WEBSITE_DIR}/index.html" ]]; then
    cat > "${WEBSITE_DIR}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Server is running</title>
    <meta charset="utf-8">
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            padding: 80px;
            background: #f5f5f5;
        }
        h1 { color: #4CAF50; }
        .box {
            background: white;
            padding: 30px;
            border-radius: 10px;
            max-width: 500px;
            margin: 0 auto;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
    </style>
</head>
<body>
    <div class="box">
        <h1>✅ Server is running</h1>
        <p>The server has been configured successfully.</p>
    </div>
</body>
</html>
HTMLEOF
    log "Создана страница по умолчанию"
fi

# Останавливаем старый nginx если есть
docker stop nginx 2>/dev/null || true
docker rm nginx 2>/dev/null || true

# FIX: если в репо есть docker-compose — не запускаем отдельный nginx
if [[ -n "$GITHUB_REPO_URL" ]] && [[ -f "${WEBSITE_DIR}/docker-compose.yml" ]]; then
    log "Запуск сайта через docker-compose..."
    cd "$WEBSITE_DIR"
    docker-compose down 2>/dev/null || true
    docker-compose up -d --build --remove-orphans
    cd - >/dev/null
else
    log "Запуск nginx..."
    docker run -d --name nginx --restart unless-stopped \
        --network webnet \
        -p 80:80 \
        -v "${WEBSITE_DIR}:/usr/share/nginx/html:ro" \
        nginx:alpine
fi

sleep 3

# Проверка nginx
if curl -s -o /dev/null -w "%{http_code}" http://localhost:80 | grep -qE "^(200|301|302)"; then
    log "✅ Nginx отвечает на порту 80"
else
    warn "⚠ Nginx не отвечает на localhost:80 — проверьте docker logs nginx"
fi

# --- 10. АВТООБНОВЛЕНИЕ СЕРТИФИКАТОВ ---
log "10. Настройка автообновления сертификатов..."

cat > /usr/local/bin/update-certs.sh << 'EOF'
#!/bin/bash
set -e
echo "[$(date)] Обновление сертификатов..."

systemctl stop xray hysteria-server

if certbot renew --quiet --standalone; then
    echo "[$(date)] Сертификаты обновлены"
    systemctl start xray hysteria-server
    docker restart nginx 2>/dev/null || true
    echo "[$(date)] Сервисы перезапущены"
else
    echo "[$(date)] Ошибка обновления" >&2
    systemctl start xray hysteria-server
    exit 1
fi
EOF

chmod +x /usr/local/bin/update-certs.sh

# FIX: проверяем что cron запущен перед добавлением задачи
systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
sleep 1

# FIX: безопасное добавление cron без зависания
CRON_JOB="0 3 * * * /usr/local/bin/update-certs.sh"
EXISTING_CRON=$(crontab -l 2>/dev/null || echo "")
if echo "$EXISTING_CRON" | grep -qF "update-certs.sh"; then
    log "Задача cron уже существует"
else
    printf "%s\n%s\n" "$EXISTING_CRON" "$CRON_JOB" | grep -v '^$' | crontab -
    log "✅ Задача cron добавлена"
fi

# --- 11. БЕЗОПАСНОСТЬ SSH ---
log "11. SSH — конфиг не меняем автоматически во избежание потери доступа к серверу"
warn "После проверки что всё работает — настройте SSH вручную (отключите пароль, добавьте ключ)"

# --- 12. ФИНАЛЬНАЯ ПРОВЕРКА ---
log "12. Финальная проверка..."
sleep 3

PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || echo "не определён")

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                   СТАТУС СЕРВИСОВ                       ║"
echo "╚══════════════════════════════════════════════════════════╝"

check_svc() {
    local svc=$1
    if systemctl is-active --quiet "$svc"; then
        echo -e "  ✅ $svc: \033[1;32mACTIVE\033[0m"
    else
        echo -e "  ❌ $svc: \033[1;31mFAILED\033[0m"
        journalctl -u "$svc" -n 5 --no-pager
    fi
}

check_svc xray
check_svc hysteria-server

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
echo "🌐 Сервер: $PUBLIC_IP | Домен: $DOMAIN"
echo ""
echo "🔐 XRAY (VLESS+Reality):"
echo "  Адрес:      ${DOMAIN}:${XRAY_PORT}"
echo "  UUID:       ${XRAY_UUID}"
echo "  Public Key: ${XRAY_PUBLIC_KEY}"
echo "  Short ID:   ${XRAY_SHORT_ID}"
echo "  Flow:       xtls-rprx-vision"
echo "  SNI:        www.google.com"
echo ""
echo "⚡ HYSTERIA2:"
echo "  Адрес:  ${DOMAIN}:${HYSTERIA_PORT}"
echo "  Пароль: ${HY_PASSWORD}"
echo "  SNI:    ${DOMAIN}"
echo ""
echo "🌍 Сайт: http://${DOMAIN}"
echo ""
echo "📋 Логи установки: ${LOG_FILE}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NekoBox конфиг VLESS:"
echo '  {'
echo '    "type": "vless",'
echo "    \"server\": \"${PUBLIC_IP}\","
echo "    \"server_port\": ${XRAY_PORT},"
echo "    \"uuid\": \"${XRAY_UUID}\","
echo '    "flow": "xtls-rprx-vision",'
echo '    "tls": {'
echo '      "enabled": true,'
echo '      "server_name": "www.google.com",'
echo '      "utls": {"enabled": true, "fingerprint": "chrome"},'
echo '      "reality": {'
echo '        "enabled": true,'
echo "        \"public_key\": \"${XRAY_PUBLIC_KEY}\","
echo "        \"short_id\": \"${XRAY_SHORT_ID}\""
echo '      }'
echo '    }'
echo '  }'
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NekoBox конфиг Hysteria2:"
echo '  {'
echo '    "type": "hysteria2",'
echo "    \"server\": \"${PUBLIC_IP}\","
echo "    \"server_port\": ${HYSTERIA_PORT},"
echo "    \"password\": \"${HY_PASSWORD}\","
echo '    "tls": {'
echo '      "enabled": true,'
echo "      \"server_name\": \"${DOMAIN}\""
echo '    }'
echo '  }'
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "\033[1;32m✅ Установка завершена!\033[0m"
echo "⚠️  Сохраните данные выше в надёжном месте!"
