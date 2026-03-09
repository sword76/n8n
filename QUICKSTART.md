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

1. **PostgreSQL должен быть запущен на хосте:**
   ```bash
   # Проверить
   pg_isready -h localhost -p 5432

   # Создать базу данных (если еще не создана)
   createdb n8n
   ```

2. **Заполнить .env файл:**
   - `POSTGRES_PASSWORD` - пароль от PostgreSQL
   - `N8N_ENCRYPTION_KEY` - сгенерировать с помощью `openssl rand -base64 32`
   - `GRAFANA_ADMIN_PASSWORD` - пароль для Grafana

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
