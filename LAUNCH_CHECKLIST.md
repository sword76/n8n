# 🚀 Чеклист запуска n8n

## ✅ Исправлено автоматически:

1. ✅ Перемещены файлы из `monitoring/promitheus/` → `monitoring/prometheus/`
2. ✅ Исправлены имена сервисов в `nginx/nginx.conf` (n8n_instance_1 → n8n1)
3. ✅ Удалены неподдерживаемые директивы health check из nginx.conf
4. ✅ Обновлен `.env.template` с переменными для Telegram

## 📝 Что нужно сделать вручную:

### 1. Создать .env файл

```bash
cp .env.template .env
```

Затем отредактировать `.env` и заполнить:

```bash
# Database (PostgreSQL управляется Docker Compose)
POSTGRES_USER=pguser
POSTGRES_PASSWORD=YOUR_STRONG_PASSWORD
POSTGRES_DB=pgdb

# Grafana
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=YOUR_GRAFANA_PASSWORD

# Telegram (for Alertmanager)
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
TELEGRAM_CHAT_ID=-1001234567890

# N8N Encryption (generate with: openssl rand -base64 32)
N8N_ENCRYPTION_KEY=YOUR_GENERATED_ENCRYPTION_KEY
```

### 2. Настроить Alertmanager (опционально)

Отредактировать `monitoring/alertmanager/alertmanager.yml`:

```bash
nano monitoring/alertmanager/alertmanager.yml
```

Заменить:
- `YOUR_BOT_TOKEN` → ваш Telegram bot token
- `YOUR_CHAT_ID` → ваш Telegram chat ID

**Как получить Telegram bot token:**
1. Открыть [@BotFather](https://t.me/botfather) в Telegram
2. Отправить `/newbot`
3. Следовать инструкциям
4. Скопировать полученный token

**Как узнать chat ID:**
1. Написать боту сообщение
2. Открыть: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
3. Найти `"chat":{"id":...}`

### 3. (Опционально) Настроить SSL

Если планируете использовать HTTPS:

```bash
# Создать самоподписанный сертификат для тестирования
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx/ssl/selfsigned.key \
  -out nginx/ssl/selfsigned.crt
```

Затем обновить `nginx/nginx.conf` для добавления HTTPS server block.

## 🚀 Запуск системы

### Первый запуск:

```bash
# 1. Убедитесь, что .env файл создан и заполнен
cat .env

# 2. Запустить все сервисы (PostgreSQL запустится автоматически)
docker-compose up -d

# 3. Проверить статус
docker-compose ps

# 4. Посмотреть логи
docker-compose logs -f
```

### Проверка работоспособности:

```bash
# n8n (через load balancer)
curl http://localhost:80/healthz

# Prometheus
curl http://localhost:9090/-/healthy

# Grafana
curl http://localhost:3000/api/health

# Alertmanager
curl http://localhost:9093/-/healthy
```

### Доступ к сервисам:

| Сервис | URL | Логин |
|--------|-----|-------|
| n8n | http://localhost:80 | Создается при первом запуске |
| Grafana | http://localhost:3000 | admin / (из .env) |
| Prometheus | http://localhost:9090 | - |
| Alertmanager | http://localhost:9093 | - |

## 🔍 Диагностика проблем

### Если n8n не запускается:

```bash
# Проверить логи
docker-compose logs n8n1
docker-compose logs n8n2

# Проверить подключение к БД (PostgreSQL — контейнер "PostgreSQL" в той же сети)
docker exec -it n8n_instance_1 sh -c "nc -zv PostgreSQL 5432"

# Проверить состояние контейнера PostgreSQL
docker-compose logs postgres
```

### Если nginx не работает:

```bash
# Проверить конфигурацию
docker exec -it n8n_nginx_load_balancer nginx -t

# Перезапустить nginx
docker-compose restart nginx
```

### Если контейнеры не видят друг друга:

```bash
# Проверить сеть
docker network inspect n8n_network

# Проверить DNS в контейнере
docker exec -it n8n_instance_1 sh -c "ping -c 2 n8n2"
```

## ⚠️ Важные замечания:

1. **PostgreSQL управляется Docker Compose** — отдельная установка на хосте не нужна
   - Контейнер: `PostgreSQL`, порт: `5432`
   - n8n подключается по имени контейнера внутри сети `n8n_network`
   - Данные хранятся в именованном volume `postgres_data`

2. **N8N_ENCRYPTION_KEY** - КРИТИЧЕСКИ ВАЖЕН!
   - Храните его в безопасности
   - При потере ключа потеряете доступ ко всем сохраненным credentials

3. **Первый запуск n8n** займет ~30-60 секунд
   - n8n инициализирует базу данных
   - Создает необходимые таблицы

4. **Мониторинг** начнет работать сразу после запуска
   - Prometheus собирает метрики каждые 15 секунд
   - Grafana автоматически подключится к Prometheus
   - Дашборды можно создать в Grafana UI

## 📊 Следующие шаги после запуска:

1. Создать admin аккаунт в n8n (http://localhost:80)
2. Настроить дашборды в Grafana
3. Настроить алерты в Prometheus/Alertmanager
4. Добавить SSL сертификаты для production
5. Настроить бэкапы PostgreSQL

## 🆘 Получить помощь:

```bash
# Остановить все сервисы
docker-compose down

# Полностью очистить (ВНИМАНИЕ: удалит volumes с данными!)
docker-compose down -v

# Пересобрать и запустить заново
docker-compose up -d --build --force-recreate
```
