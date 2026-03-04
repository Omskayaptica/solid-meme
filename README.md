# Server Setup v6.0

Автоматическая настройка VPN-сервера с двумя режимами на выбор.

## Режимы

**Режим 1 — VLESS + Reality**
- Домен не нужен (опционально для Hysteria2)
- Маскировка под иностранный сайт (по умолчанию `www.google.com`)
- Быстрая установка

**Режим 2 — VLESS + TLS + Реальный сайт**
- Нужен домен и GitHub репозиторий с сайтом
- Xray притворяется вашим настоящим сайтом
- Устойчивее к блокировкам в РФ

В обоих режимах устанавливается:
- **Xray** — VLESS на порту 443 TCP
- **Hysteria2** — быстрый UDP протокол на порту 8443
- **Nginx** — веб-сервер на порту 80
- **SSL сертификат** — Let's Encrypt, автообновление
- **UFW** — фаервол
- **Fail2ban** — защита от брутфорса

---

## Требования

- **Сервер** — Ubuntu 22.04, минимум 512MB RAM
- **Домен** (для режима 2, для Hysteria2 в режиме 1) — A-запись направлена на IP сервера
- **Порты открыты** у хостера — 22, 80, 443 TCP и 8443 UDP

### Проверка DNS перед запуском
```bash
# На вашем ПК:
dig +short ваш-домен.com
# Должен вернуть IP сервера
```

---

## Установка

### 1. Загрузите скрипт на сервер

**Mac / Linux:**
```bash
scp setup.sh root@IP_СЕРВЕРА:/root/setup.sh
```

**Windows (PowerShell):**
```powershell
scp $env:USERPROFILE\Downloads\setup.sh root@IP_СЕРВЕРА:/root/setup.sh
```

### 2. Подключитесь и запустите

```bash
ssh root@IP_СЕРВЕРА
chmod +x /root/setup.sh && bash /root/setup.sh
```

### 3. Ответьте на вопросы

**Режим 1 (Reality):**
```
Выберите режим [1/2]: 1
Введите Email для сертификатов: ваш@email.com
Введите домен (или оставьте пустым): ваш-домен.com
SNI для Reality [www.google.com]: [Enter]
```

**Режим 2 (TLS+Сайт):**
```
Выберите режим [1/2]: 2
Введите Email для сертификатов: ваш@email.com
Введите домен: ваш-домен.com
GitHub URL репозитория: https://github.com/ваш/репо
Turnstile Site Key: ...
SMTP User: ...
```

### 4. Скрипт запустится внутри screen

Если SSH оборвётся — переподключитесь и выполните:
```bash
screen -r server-setup
```

Установка занимает **5–15 минут**. В конце скрипт выведет данные для подключения.

---

## Если закрыли окно до конца установки

Данные для подключения сохраняются в лог файле:

```bash
# Показать финальный вывод из лога
cat $(ls -t /var/log/server-setup-*.log | head -1) | grep -A3 -E "(UUID|Public Key|Short ID|Пароль|VLESS|hysteria2|NekoBox)"

# Весь лог целиком
cat $(ls -t /var/log/server-setup-*.log | head -1)
```

Или достать данные напрямую из конфигов:

```bash
# UUID и ключи Xray
cat /usr/local/etc/xray/config.json | python3 -m json.tool | grep -E '(id|publicKey|shortIds|port)'

# Hysteria2 пароль
grep password /etc/hysteria/config.yaml

# IP сервера
hostname -I | awk '{print $1}'
```

---

## Данные для подключения

### Режим 1 — VLESS + Reality

**VLESS ссылка:**
```
vless://UUID@IP:443?type=tcp&encryption=none&flow=xtls-rprx-vision&security=reality&sni=SNI&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID#MyServer
```

**NekoBox JSON:**
```json
{
  "type": "vless",
  "server": "IP_СЕРВЕРА",
  "server_port": 443,
  "uuid": "ВАШ_UUID",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "www.google.com",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": {
      "enabled": true,
      "public_key": "ВАШ_PUBLIC_KEY",
      "short_id": "ВАШ_SHORT_ID"
    }
  }
}
```

### Режим 2 — VLESS + TLS

**VLESS ссылка:**
```
vless://UUID@IP:443?type=tcp&encryption=none&flow=xtls-rprx-vision&security=tls&sni=ДОМЕН&fp=chrome#MyServer
```

**NekoBox JSON:**
```json
{
  "type": "vless",
  "server": "IP_СЕРВЕРА",
  "server_port": 443,
  "uuid": "ВАШ_UUID",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "ВАШ_ДОМЕН",
    "utls": { "enabled": true, "fingerprint": "chrome" }
  }
}
```

### Hysteria2 (оба режима)

**VLESS ссылка:**
```
hysteria2://ПАРОЛЬ@IP:8443?sni=ДОМЕН#MyServer-Hysteria2
```

**NekoBox JSON:**
```json
{
  "type": "hysteria2",
  "server": "IP_СЕРВЕРА",
  "server_port": 8443,
  "password": "ВАШ_ПАРОЛЬ",
  "tls": {
    "enabled": true,
    "server_name": "ВАШ_ДОМЕН"
  }
}
```

**Как импортировать в NekoBox:**
1. Нажмите **+** → **Manual input**
2. Переключитесь на вкладку **JSON**
3. Вставьте конфиг и сохраните

---

## Диагностика

```bash
# Статус всех сервисов
systemctl status xray hysteria-server --no-pager

# Открытые порты (должны быть 80, 443, 8443)
ss -tulpn | grep -E '(80|443|8443)'

# Docker контейнеры
docker ps

# Логи Xray
journalctl -u xray -f

# Логи Hysteria2
journalctl -u hysteria-server -f

# Логи сайта (режим 2)
docker logs mysite_nginx --tail 50
docker logs mysite_php --tail 50

# Лог установки
cat $(ls -t /var/log/server-setup-*.log | head -1)
```

---

## Частые проблемы

| Проблема | Причина | Решение |
|----------|---------|---------|
| Сертификат не выдаётся | DNS не распространился или порт 80 занят | Подождать 15 мин, проверить `dig +short домен` |
| Too many certificates | Лимит Let's Encrypt — 5 сертификатов за 7 дней | Использовать другой поддомен или ждать |
| SSH недоступен после скрипта | UFW сбросил правила | Зайти через веб-консоль хостера: `ufw allow 22` |
| VLESS не подключается (Reality) | Несовпадение ключей | Сверить `publicKey` в конфиге и в клиенте |
| Сайт отдаёт 404 (режим 2) | docker-compose не запустился | `docker logs mysite_nginx` |
| Hysteria2 ошибка 301 | masquerade идёт на http вместо https | `sed -i 's\|http://127.0.0.1:80/\|https://домен/\|' /etc/hysteria/config.yaml && systemctl restart hysteria-server` |
| Xray запускается от nobody | Drop-in файл установщика | `rm -rf /etc/systemd/system/xray.service.d && systemctl daemon-reload && systemctl restart xray` |

---

## Структура файлов

```
/usr/local/bin/xray                      — бинарник Xray
/usr/local/etc/xray/config.json          — конфиг Xray
/usr/local/bin/hysteria                  — бинарник Hysteria2
/etc/hysteria/config.yaml                — конфиг Hysteria2
/root/server-setup/website/              — файлы сайта
/usr/local/bin/update-certs.sh           — скрипт обновления сертификатов
/var/log/server-setup-*.log              — лог установки
```

---

## Обновление сертификатов

Автоматически каждую ночь в 03:00. Проверить:
```bash
crontab -l
```

Запустить вручную:
```bash
/usr/local/bin/update-certs.sh
```
