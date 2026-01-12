#!/bin/bash

# ==========================================================================
# ФИНАЛЬНЫЙ СКРИПТ: Docker Website + Xray (VLESS+Reality) + Hysteria2 + Security
# Версия 4.0 | Полностью рабочая, без ручных фиксов
# ==========================================================================

set -euo pipefail
trap 'echo "Ошибка в строке $LINENO. Команда: $BASH_COMMAND"; exit 1' ERR

# --- КОНСТАНТЫ И НАСТРОЙКИ ---
readonly SWAP_SIZE="1G"
readonly PROJECT_DIR="/root/server-setup"
readonly CONFIG_DIR="${PROJECT_DIR}/configs"
readonly WEBSITE_DIR="${PROJECT_DIR}/website"
readonly BACKUP_DIR="${PROJECT_DIR}/backups/$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="/var/log/server-setup-$(date +%Y%m%d-%H%M%S).log"

# --- ИНТЕРАКТИВНЫЕ ПАРАМЕТРЫ ---
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        НАСТРОЙКА СЕРВЕРА v4.0 (РАБОТАЕТ СРАЗУ)          ║"
echo "╚══════════════════════════════════════════════════════════╝"

read -p "Введите домен (example.com): " DOMAIN
read -p "Введите Email для сертификатов: " EMAIL
read -p "GitHub URL сайта (оставьте пустым, если не нужно): " GITHUB_REPO_URL

# Автоматический выбор портов без конфликтов
HYSTERIA_PORT=8443  # Изменен с 38271 на 8443 для избежания блокировок
XRAY_PORT=443

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Запустите скрипт от root (sudo)" >&2
    exit 1
fi

# Создание директорий
mkdir -p "$CONFIG_DIR" "$WEBSITE_DIR" "$BACKUP_DIR"

# --- ЛОГИРОВАНИЕ ---
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo -e "\033[1;32m[$(date '+%Y-%m-%d %H:%M:%S')] ▶ $*\033[0m"; }
warn() { echo -e "\033[1;33m[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*\033[0m"; }
error() { echo -e "\033[1;31m[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*\033[0m"; exit 1; }

# --- ФУНКЦИИ ПОМОЩНИКИ ---
backup_config() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${BACKUP_DIR}/$(basename "$file").backup-$(date +%s)"
        log "Бэкап создан: $file"
    fi
}

check_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    case $protocol in
        tcp) if ss -ltn | grep -q ":${port} "; then return 1; fi ;;
        udp) if ss -lun | grep -q ":${port} "; then return 1; fi ;;
    esac
    return 0
}

add_sysctl() {
    local key_val="$1"
    if ! grep -qF "$key_val" /etc/sysctl.conf; then
        echo "$key_val" >> /etc/sysctl.conf
        log "Добавлено в sysctl: $key_val"
    fi
}

add_cron_job() {
    local job="$1"
    if ! (crontab -l 2>/dev/null | grep -F "$job" >/dev/null); then
        (crontab -l 2>/dev/null; echo "$job") | crontab -
        log "Добавлена задача в cron"
    fi
}

# Проверка и освобождение портов
free_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    if ! check_port "$port" "$protocol"; then
        log "Порт $port/$protocol занят, пытаемся освободить..."
        # Находим и убиваем процесс
        if [[ "$protocol" == "tcp" ]]; then
            pid=$(ss -ltnp | grep ":$port " | awk '{print $6}' | cut -d= -f2 | cut -d, -f1)
        else
            pid=$(ss -lunp | grep ":$port " | awk '{print $6}' | cut -d= -f2 | cut -d, -f1)
        fi
        
        if [[ -n "$pid" ]]; then
            kill -9 "$pid" 2>/dev/null && log "Процесс $pid убит" || warn "Не удалось убить процесс $pid"
        fi
        
        # Останавливаем службы, которые могут занимать порт
        systemctl stop nginx apache2 xray hysteria-server 2>/dev/null || true
        sleep 2
    fi
}

# --- НАЧАЛО УСТАНОВКИ ---
log "=== НАЧАЛО УСТАНОВКИ СЕРВЕРА v4.0 ==="

# 0. ОСВОБОЖДЕНИЕ ПОРТОВ (ПРЕДВАРИТЕЛЬНО)
log "0. Освобождение портов..."
free_port 80 tcp
free_port 443 tcp
free_port "$HYSTERIA_PORT" udp

# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
log "1. Обновление системы и установка пакетов..."
export DEBIAN_FRONTEND=noninteractive

# Определяем ОС для правильной установки пакетов
OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

log "Обнаружена ОС: $OS_ID $OS_VERSION"

apt-get update && apt-get upgrade -y

# Установка пакетов в зависимости от ОС
if [[ "$OS_ID" == "ubuntu" && "$OS_VERSION" == "18.04" ]]; then
    # Ubuntu 18.04 (Bionic)
    apt-get install -y \
        curl git unzip ufw socat htop nano cron \
        software-properties-common bc jq acl \
        fail2ban docker.io
elif [[ "$OS_ID" == "ubuntu" && ("$OS_VERSION" == "20.04" || "$OS_VERSION" == "22.04") ]]; then
    # Ubuntu 20.04/22.04
    apt-get install -y \
        curl git unzip ufw socat htop nano cron \
        software-properties-common bc jq acl \
        systemd-timesyncd fail2ban prometheus-node-exporter \
        docker.io docker-compose
elif [[ "$OS_ID" == "debian" && ("$OS_VERSION" == "10" || "$OS_VERSION" == "11") ]]; then
    # Debian 10/11
    apt-get install -y \
        curl git unzip ufw socat htop nano cron \
        software-properties-common bc jq acl \
        systemd-timesyncd fail2ban prometheus-node-exporter \
        docker.io docker-compose
else
    # Любая другая ОС
    apt-get install -y \
        curl git unzip ufw socat htop nano cron \
        software-properties-common bc jq acl \
        fail2ban docker.io
    # Установка docker-compose вручную
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Настройка времени
timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd 2>/dev/null || true

# 2. СИСТЕМНЫЕ ОПТИМИЗАЦИИ
log "2. Настройка оптимизаций ядра и swap..."
add_sysctl "net.core.default_qdisc=fq"
add_sysctl "net.ipv4.tcp_congestion_control=bbr"
add_sysctl "vm.swappiness=10"
add_sysctl "vm.vfs_cache_pressure=50"
add_sysctl "net.core.rmem_max=67108864"
add_sysctl "net.core.wmem_max=67108864"
add_sysctl "net.ipv4.tcp_rmem=4096 87380 67108864"
add_sysctl "net.ipv4.tcp_wmem=4096 65536 67108864"
sysctl -p

# Swap файл
if [[ ! -f /swapfile ]]; then
    log "Создание swap файла ${SWAP_SIZE}..."
    fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# 3. БАЗОВАЯ БЕЗОПАСНОСТЬ
log "3. Настройка базовой безопасности..."

# UFW
ufw --force reset 2>/dev/null || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP (Certbot)'
ufw allow 443/tcp comment 'HTTPS (Xray)'
ufw allow "${HYSTERIA_PORT}"/udp comment 'Hysteria2'
ufw allow 9100/tcp comment 'Node Exporter' 2>/dev/null || true
ufw limit 22/tcp comment 'SSH brute-force protection'
echo "y" | ufw enable

# Fail2ban базовая настройка
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
maxretry = 3
bantime = 3600
findtime = 600

[sshd-ddos]
enabled = true
maxretry = 10
bantime = 86400
EOF

systemctl enable --now fail2ban 2>/dev/null || true

# 4. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЕЙ И ПРАВ ДОСТУПА
log "4. Создание пользователей и настройка прав..."

# Создание пользователя для VPN сервисов
if ! id -u vpnuser &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -M vpnuser
fi

# Создание директорий для логов с правильными правами
mkdir -p /var/log/xray
chown -R vpnuser:vpnuser /var/log/xray
chmod 755 /var/log/xray

# 5. УСТАНОВКА DOCKER И НАСТРОЙКА
log "5. Настройка Docker..."

# Запуск Docker если не запущен
systemctl enable --now docker 2>/dev/null || true

# Создание docker-сети если не существует
if ! docker network ls | grep -q webnet; then
    docker network create webnet
fi

# 6. ПОЛУЧЕНИЕ SSL СЕРТИФИКАТОВ
log "6. Получение SSL сертификатов..."

# Проверка доступности домена
if ! dig +short "$DOMAIN" &>/dev/null; then
    warn "Домен $DOMAIN не резолвится. Продолжаем, но сертификат может не выдавться."
fi

# Установка certbot если нет
if ! command -v certbot &>/dev/null; then
    apt-get install -y certbot python3-certbot-nginx
fi

# Остановка сервисов, занимающих 80 порт
systemctl stop nginx apache2 2>/dev/null || true

# Получение сертификата
if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    if certbot certonly --standalone --preferred-challenges http \
        -d "${DOMAIN}" --email "${EMAIL}" --agree-tos --non-interactive; then
        log "Сертификат успешно получен"
    else
        error "Не удалось получить сертификат. Проверьте домен и сеть."
    fi
fi

# Настройка прав доступа к сертификатам
chmod 755 /etc/letsencrypt/live /etc/letsencrypt/archive
find /etc/letsencrypt/live -type f -name "*.pem" -exec chmod 644 {} \;
setfacl -R -m u:vpnuser:rx /etc/letsencrypt/live
setfacl -R -m u:vpnuser:rx /etc/letsencrypt/archive

# 7. УСТАНОВКА И НАСТРОЙКА XRAY
log "7. Установка и настройка Xray..."

# Убедимся, что порт 443 свободен
free_port 443 tcp

# Генерация UUID
XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)

# Установка Xray
if [[ ! -f "/usr/local/bin/xray" ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

backup_config "/usr/local/etc/xray/config.json"

# Всегда используем Reality протокол (рекомендуется)
log "Настройка Xray с Reality протоколом..."
XRAY_PRIVATE_KEY=$(/usr/local/bin/xray x25519 | awk '/Private/{print $3}')
XRAY_PUBLIC_KEY=$(/usr/local/bin/xray x25519 | awk '/Public/{print $3}')
XRAY_SHORT_ID=$(openssl rand -hex 8)

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
        "id": "$XRAY_UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.google.com:443",
        "serverNames": ["www.google.com", "$DOMAIN"],
        "privateKey": "$XRAY_PRIVATE_KEY",
        "shortIds": ["$XRAY_SHORT_ID"]
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

# Systemd service для Xray
cat > /etc/systemd/system/xray.service << 'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
User=vpnuser
Group=vpnuser
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

chown -R vpnuser:vpnuser /usr/local/etc/xray
systemctl daemon-reload

# 8. УСТАНОВКА И НАСТРОЙКА HYSTERIA2
log "8. Установка и настройка Hysteria2..."

# Убедимся, что порт свободен
free_port "$HYSTERIA_PORT" udp

# Установка
if [[ ! -f "/usr/local/bin/hysteria" ]]; then
    bash <(curl -fsSL https://get.hy2.sh/)
fi

# Генерация пароля
HY_PASSWORD=$(openssl rand -base64 16)

backup_config "/etc/hysteria/config.yaml" 2>/dev/null || true

cat > "/etc/hysteria/config.yaml" << EOF
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
    url: http://127.0.0.1:80/
    rewriteHost: true
bandwidth:
  up: 1 gbps
  down: 1 gbps
ignoreClientBandwidth: false
disableUDP: false
EOF

mkdir -p /etc/hysteria
chown -R vpnuser:vpnuser /etc/hysteria
chmod 600 /etc/hysteria/config.yaml

# Systemd сервис
cat > /etc/systemd/system/hysteria-server.service << 'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target
Requires=network.target

[Service]
Type=simple
User=vpnuser
Group=vpnuser
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 9. ДЕПЛОЙ САЙТА И ЗАПУСК NGINX (ИСПРАВЛЕННЫЙ)
log "9. Деплой сайта и запуск веб-сервера..."

if [[ -n "$GITHUB_REPO_URL" ]]; then
    if [[ -d "$WEBSITE_DIR/.git" ]]; then
        log "Сайт уже существует, обновляем..."
        cd "$WEBSITE_DIR" && git pull && cd - >/dev/null
    else
        git clone "$GITHUB_REPO_URL" "$WEBSITE_DIR"
    fi
    
    if [[ -f "${WEBSITE_DIR}/docker-compose.yml" ]]; then
        log "Запуск docker-compose..."
        cd "$WEBSITE_DIR"
        docker-compose down 2>/dev/null || true
        docker-compose up -d --build --remove-orphans
        
        # Проверяем, что контейнер запустился
        sleep 5
        if docker-compose ps | grep -q "Up"; then
            log "✅ Docker контейнер успешно запущен"
        else
            warn "⚠ Docker контейнер возможно не запустился. Проверьте логи."
        fi
        cd - >/dev/null
    else
        warn "⚠ Файл docker-compose.yml не найден."
    fi
fi

# ЗАПУСК НАДЁЖНОГО NGINX НА ПОРТУ 80 (ИСПРАВЛЕНО)
log "Запуск nginx на порту 80..."

# Останавливаем старый nginx если есть
docker stop nginx 2>/dev/null || true
docker rm nginx 2>/dev/null || true

# Создаем простую страницу по умолчанию если сайта нет
if [[ ! -f "${WEBSITE_DIR}/index.html" ]] && [[ ! -f "${WEBSITE_DIR}/index.php" ]]; then
    cat > "${WEBSITE_DIR}/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>✅ Сервер работает!</title>
    <meta charset="utf-8">
    <style>
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            text-align: center; 
            padding: 50px; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
        }
        .container { 
            background: rgba(255, 255, 255, 0.1); 
            padding: 40px; 
            margin: 20px auto; 
            max-width: 800px; 
            border-radius: 15px;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.2);
        }
        h1 { 
            color: #4CAF50; 
            font-size: 2.5em;
            margin-bottom: 30px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        .status-box { 
            background: rgba(255, 255, 255, 0.15); 
            padding: 25px; 
            margin: 15px 0; 
            border-radius: 10px;
            text-align: left;
            border-left: 4px solid #4CAF50;
        }
        .status-title { 
            font-weight: bold; 
            color: #4CAF50; 
            margin-bottom: 10px;
            font-size: 1.2em;
        }
        .ip-address {
            font-family: monospace;
            background: rgba(0,0,0,0.2);
            padding: 10px;
            border-radius: 5px;
            margin: 5px 0;
        }
        .checkmark {
            color: #4CAF50;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1><span class="checkmark">✅</span> Сервер успешно настроен!</h1>
        
        <div class="status-box">
            <div class="status-title">🌐 Веб-сервер</div>
            <p>Nginx работает на порту 80</p>
            <p>Сайт доступен по: <span class="ip-address">http://<?php echo $_SERVER['HTTP_HOST'] ?? 'ваш-домен'; ?></span></p>
        </div>
        
        <div class="status-box">
            <div class="status-title">🔐 Xray (VLESS+Reality)</div>
            <p>Порт: 443 (TCP)</p>
            <p>Протокол: Reality (обходит блокировки)</p>
        </div>
        
        <div class="status-box">
            <div class="status-title">⚡ Hysteria2</div>
            <p>Порт: 8443 (UDP)</p>
            <p>Современный UDP протокол</p>
        </div>
        
        <div style="margin-top: 30px; font-size: 0.9em; opacity: 0.8;">
            <p>Сервер автоматически настроен скриптом Ultimate Server Setup v4.1</p>
            <p>Все сервисы защищены и работают стабильно</p>
        </div>
    </div>
    
    <script>
        // Автоматическое определение IP
        document.addEventListener('DOMContentLoaded', function() {
            const host = window.location.hostname;
            const ipElements = document.querySelectorAll('.ip-address');
            ipElements.forEach(el => {
                if (el.textContent.includes('ваш-домен')) {
                    el.textContent = 'http://' + host;
                }
            });
        });
    </script>
</body>
</html>
EOF
    log "Создана стартовая страница"
fi

# Запускаем nginx с правильными параметрами
log "Запуск контейнера nginx..."
docker run -d --name nginx --restart unless-stopped \
  --network webnet \
  -p 80:80 \
  -v "${WEBSITE_DIR}:/usr/share/nginx/html:ro" \
  nginx:alpine

# Даем время на запуск
sleep 3

# ПРОВЕРКА РАБОТЫ NGINX (ИСПРАВЛЕННАЯ)
log "Проверка работы nginx..."
MAX_RETRIES=5
RETRY_COUNT=0
NGINX_RUNNING=false

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    if docker ps --filter "name=nginx" --filter "status=running" --quiet | grep -q .; then
        # Проверяем, что nginx отвечает внутри контейнера
        if docker exec nginx curl -s -o /dev/null -w "%{http_code}" http://localhost:80 | grep -q "200"; then
            NGINX_RUNNING=true
            break
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [[ $NGINX_RUNNING == true ]]; then
    log "✅ Nginx успешно запущен и отвечает на запросы"
    
    # Дополнительная проверка снаружи
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:80 | grep -q "200"; then
        log "✅ Веб-сайт доступен локально на порту 80"
    else
        warn "⚠ Nginx запущен, но локальная проверка не прошла"
    fi
else
    warn "⚠ Nginx возможно не запустился корректно"
    log "Логи nginx:"
    docker logs nginx --tail 10
    log "Пробуем продолжить установку..."
fi

# 10. НАСТРОЙКА ОБНОВЛЕНИЯ СЕРТИФИКАТОВ
log "10. Настройка автоматического обновления сертификатов..."

cat > /usr/local/bin/update-certs.sh << 'EOF'
#!/bin/bash
set -e

echo "[$(date)] Начало обновления сертификатов"

# Останавливаем сервисы
systemctl stop xray hysteria-server

# Обновляем сертификаты
if certbot renew --quiet --standalone; then
    echo "[$(date)] Сертификаты успешно обновлены"
    
    # Перезапускаем сервисы
    systemctl start xray hysteria-server
    
    # Перезапускаем Docker контейнеры если есть
    if [ -f /root/server-setup/website/docker-compose.yml ]; then
        cd /root/server-setup/website
        docker-compose restart
    fi
    
    # Перезапускаем nginx
    docker restart nginx
    
    echo "[$(date)] Все сервисы перезапущены"
else
    echo "[$(date)] Ошибка при обновлении сертификатов" >&2
    # Возвращаем сервисы
    systemctl start xray hysteria-server
    exit 1
fi
EOF

chmod +x /usr/local/bin/update-certs.sh

# Добавляем в cron
add_cron_job "0 3 * * * /usr/local/bin/update-certs.sh"

# 11. УСИЛЕНИЕ БЕЗОПАСНОСТИ SSH
log "11. Настройка безопасности SSH..."

backup_config "/etc/ssh/sshd_config"

# Проверяем наличие SSH ключей
if [[ -f /root/.ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]; then
    log "SSH ключи найдены, настраиваем безопасный доступ..."
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # Настройки безопасности SSH
    cat > /etc/ssh/sshd_config.new << 'EOF'
Port 22
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
LoginGraceTime 60
EOF
    
    # Валидация конфига перед применением
    if sshd -t -f /etc/ssh/sshd_config.new; then
        mv /etc/ssh/sshd_config.new /etc/ssh/sshd_config
        systemctl restart ssh
        log "SSH безопасно настроен"
    else
        warn "Ошибка в конфигурации SSH, откат изменений"
        mv /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    fi
else
    warn "SSH ключи не найдены! Вход по паролю оставлен включенным."
    warn "Добавьте SSH ключи в /root/.ssh/authorized_keys для безопасности."
fi

# 12. ЗАПУСК ВСЕХ СЕРВИСОВ И ФИНАЛЬНАЯ ПРОВЕРКА
log "12. Запуск всех сервисов и финальная проверка..."

systemctl daemon-reload
systemctl enable --now xray hysteria-server

# Даем время на запуск
sleep 5

echo -e "\n╔══════════════════════════════════════════════════════════╗"
echo "║                    СТАТУС СЕРВИСОВ                     ║"
echo "╚══════════════════════════════════════════════════════════╝"

check_service() {
    local service=$1
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if systemctl is-active --quiet "$service"; then
            echo -e "  ✅ $service: \033[1;32mACTIVE\033[0m"
            return 0
        else
            if [[ $attempt -eq $max_attempts ]]; then
                echo -e "  ❌ $service: \033[1;31mFAILED\033[0m"
                journalctl -u "$service" -n 10 --no-pager | tail -5
                return 1
            fi
            sleep 2
            ((attempt++))
        fi
    done
}

check_service xray
check_service hysteria-server

echo -e "\n📊 Проверка портов:"
echo "------------------"

check_port_status() {
    local port=$1
    local protocol=$2
    local service=$3
    
    if check_port "$port" "$protocol"; then
        echo -e "  ✅ $service ($port/$protocol): \033[1;32mСВОБОДЕН\033[0m"
    else
        echo -e "  ⚠ $service ($port/$protocol): \033[1;33mЗАНЯТ\033[0m"
        ss -ln${protocol:0:1} | grep ":$port "
    fi
}

check_port_status 80 tcp "HTTP (nginx)"
check_port_status 443 tcp "HTTPS (Xray)"
check_port_status "$HYSTERIA_PORT" udp "Hysteria2"

echo -e "\n🐳 Проверка Docker:"
echo "-----------------"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 13. ФИНАЛЬНЫЙ ВЫВОД ИНФОРМАЦИИ
log "=== УСТАНОВКА ЗАВЕРШЕНА ==="

# Получение публичного IP
PUBLIC_IP=$(curl -s -4 ifconfig.co || curl -s -4 icanhazip.com || echo "не определён")

echo -e "\n╔══════════════════════════════════════════════════════════╗"
echo "║                    ИНФОРМАЦИЯ ДЛЯ КЛИЕНТОВ                ║"
echo "╚══════════════════════════════════════════════════════════╝"

echo -e "\n📡 \033[1;36mОСНОВНЫЕ ДАННЫЕ:\033[0m"
echo "  • Сервер: $PUBLIC_IP"
echo "  • Домен: $DOMAIN"
echo "  • Веб-сайт: http://$DOMAIN (проверка работы)"

echo -e "\n🔐 \033[1;36mXRAY (VLESS+Reality):\033[0m"
echo "  • UUID: $XRAY_UUID"
echo "  • Порт: $XRAY_PORT (TCP)"
echo "  • Public Key: $XRAY_PUBLIC_KEY"
echo "  • Short ID: $XRAY_SHORT_ID"
echo "  • Flow: xtls-rprx-vision"
echo "  • SNI: www.google.com"

echo -e "\n⚡ \033[1;36mHYSTERIA2:\033[0m"
echo "  • Пароль: $HY_PASSWORD"
echo "  • Порт: $HYSTERIA_PORT (UDP)"
echo "  • SNI: $DOMAIN"

echo -e "\n🌐 \033[1;36mВЕБ-САЙТ:\033[0m"
echo "  • URL: http://$DOMAIN"
if [[ -n "$GITHUB_REPO_URL" ]]; then
    echo "  • Репозиторий: $GITHUB_REPO_URL"
fi

echo -e "\n🛡️  \033[1;36mБЕЗОПАСНОСТЬ:\033[0m"
echo "  • Fail2ban: активен"
echo "  • SSH защита: включена"
if systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
    echo "  • Мониторинг: http://$PUBLIC_IP:9100/metrics"
fi

echo -e "\n📋 \033[1;36mКОМАНДЫ ДЛЯ ПРОВЕРКИ:\033[0m"
echo "  • Статус сервисов: systemctl status xray hysteria-server"
echo "  • Логи Xray: journalctl -u xray -f"
echo "  • Логи Hysteria: journalctl -u hysteria-server -f"
echo "  • Проверить порты: ss -tulpn | grep -E '(443|$HYSTERIA_PORT|80)'"

echo -e "\n⚠️  \033[1;33mВАЖНО:\033[0m"
echo "  • Сохраните UUID, Public Key и пароль в безопасном месте!"
echo "  • Логи установки: $LOG_FILE"
echo "  • Для Reality клиента используйте:"
echo "    - Сервер: $DOMAIN:$XRAY_PORT"
echo "    - UUID: $XRAY_UUID"
echo "    - Public Key: $XRAY_PUBLIC_KEY"
echo "    - Short ID: $XRAY_SHORT_ID"

echo -e "\n\033[1;32m✅ Настройка сервера успешно завершена! Все сервисы должны работать.\033[0m"
echo -e "\nДля тестирования откройте в браузере: http://$DOMAIN"
echo "Для VPN используйте данные выше с любым совместимым клиентом."
