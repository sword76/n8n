# ⚡ Быстрый старт

## Минимальные шаги для запуска:

```bash
# 1. Создать .env файл
cp .env.template .env

# 2. Сгенерировать encryption key
openssl rand -base64 32

# 3. Отредактировать .env (вставить ваш encryption key и пароли)
nano .env

# 4. Запустить все сервисы
docker-compose up -d

# 5. Открыть n8n в браузере
# http://localhost:80
```

## ⚠️ Важные требования:

1. **Заполнить .env файл:**
   - `POSTGRES_USER` - имя пользователя PostgreSQL (например, `pguser`)
   - `POSTGRES_PASSWORD` - пароль PostgreSQL
   - `POSTGRES_DB` - имя базы данных (например, `pgdb`)
   - `N8N_ENCRYPTION_KEY` - сгенерировать с помощью `openssl rand -base64 32`
   - `GRAFANA_ADMIN_PASSWORD` - пароль для Grafana

   > **Примечание:** PostgreSQL теперь полностью управляется Docker Compose — отдельная установка на хосте не требуется.

## 📊 После запуска доступны:

- n8n: http://localhost:80
- Grafana: http://localhost:3000 (admin/your_password)
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093

## 🔍 Проверка статуса:

```bash
docker-compose ps
docker-compose logs -f
```

Подробная документация: [LAUNCH_CHECKLIST.md](./LAUNCH_CHECKLIST.md)
