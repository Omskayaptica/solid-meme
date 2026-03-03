# Server Setup v5.1

Автоматическая настройка VPN-сервера с сайтом-прикрытием.

## Что устанавливается

- **Xray** — VLESS + Reality (порт 443 TCP)
- **Hysteria2** — быстрый UDP протокол (порт 8443 UDP)
- **Nginx** — веб-сайт на порту 80 (прикрытие)
- **SSL сертификат** — Let's Encrypt, автообновление
- **UFW** — фаервол
- **Fail2ban** — защита от брутфорса

---

## Требования перед запуском

1. **Сервер** — Ubuntu 22.04, минимум 512MB RAM
2. **Домен** — направлен A-записью на IP сервера
3. **DNS** — распространился (проверить: `dig +short ваш-домен`)
4. **Порты** — 22, 80, 443 TCP и 8443 UDP открыты у хостера

### Проверка DNS
```bash
# На вашем ПК:
dig +short ваш-домен.com
# Должен вернуть IP сервера
```

---

## Установка

### 1. Загрузите скрипт на сервер

**Mac / Linux** (в терминале на вашем ПК):
```bash
scp setup.sh root@IP_СЕРВЕРА:/root/setup.sh
```

**Windows** (в PowerShell):
```powershell
scp $env:USERPROFILE\Downloads\setup.sh root@IP_СЕРВЕРА:/root/setup.sh
```

### 2. Подключитесь к серверу
```bash
ssh root@IP_СЕРВЕРА
```

### 3. Запустите скрипт
```bash
chmod +x /root/setup.sh && bash /root/setup.sh
```

### 4. Введите данные
```
Введите домен (example.com): ваш-домен.com
Введите Email для сертификатов: ваш@email.com
GitHub URL сайта (оставьте пустым, если не нужно): [Enter]
```

Скрипт автоматически запустится внутри `screen` — если SSH оборвётся, переподключитесь и выполните:
```bash
screen -r server-setup
```

### 5. Дождитесь завершения
Установка занимает **5–10 минут**. В конце все сервисы должны показать ✅.

---

## Получение данных для подключения

После установки выполните на сервере:

```bash
# Xray данные
cat /usr/local/etc/xray/config.json | python3 -m json.tool | grep -E '(id|publicKey|shortIds|port)'

# Hysteria2 пароль
grep password /etc/hysteria/config.yaml

# IP сервера
hostname -I | awk '{print $1}'
```

---

## Подключение клиентов

### NekoBox (Windows / Android)

**VLESS + Reality:**
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

**Hysteria2:**
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

## Проверка работы

```bash
# Статус сервисов
systemctl status xray hysteria-server --no-pager

# Открытые порты
ss -tulpn | grep -E '(80|443|8443)'

# Docker
docker ps

# Логи Xray
journalctl -u xray -f

# Логи Hysteria2
journalctl -u hysteria-server -f
```

---

## Возможные проблемы

| Проблема | Причина | Решение |
|----------|---------|---------|
| Сертификат не выдаётся | DNS не распространился или порт 80 закрыт | Подождать 15 мин, проверить `dig` |
| Xray не стартует | Порт 443 занят | `ss -tulpn \| grep 443`, убить процесс |
| SSH недоступен после скрипта | UFW сбросил правила | Зайти через веб-консоль хостера, выполнить `ufw allow 22` |
| Too many certificates | Лимит Let's Encrypt (5 за 7 дней) | Использовать другой поддомен или ждать |
| VLESS не подключается | Неверный public key | Сверить ключ в конфиге с тем что в клиенте |

---

## Структура файлов

```
/usr/local/bin/xray                    — бинарник Xray
/usr/local/etc/xray/config.json        — конфиг Xray
/usr/local/bin/hysteria                — бинарник Hysteria2
/etc/hysteria/config.yaml              — конфиг Hysteria2
/root/server-setup/website/            — файлы сайта
/usr/local/bin/update-certs.sh         — скрипт обновления сертификатов
/var/log/server-setup-*.log            — лог установки
```

---

## Обновление сертификатов

Происходит автоматически каждую ночь в 03:00. Проверить:
```bash
crontab -l
```

Запустить вручную:
```bash
/usr/local/bin/update-certs.sh
```
