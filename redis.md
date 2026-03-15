# Redis + n8n Queue Mode — Implementation Plan

---

## Фаза 0 — Предварительная работа (сначала критические баги)

| # | Файл | Исправление |
|---|---|---|
| 1 | `nginx/nginx.conf` | Добавить блок `map $http_upgrade $connection_upgrade`; заменить `Connection "upgrade"` → `Connection $connection_upgrade` |
| 2 | `nginx/nginx.conf` | Добавить `ip_hash;` в upstream (для привязки сессий редактора к конкретному серверу) |

---

## Фаза 1 — Добавление Redis

Добавить сервис `redis` в `docker-compose.yml`:
- Образ: `redis:7-alpine`
- AOF-персистентность (`appendonly yes`) — при сбое теряется максимум 1 секунда данных, в отличие от нескольких минут при использовании RDB-снимков
- Защита паролем через `${REDIS_PASSWORD}`
- `maxmemory 256mb` + политика вытеснения `allkeys-lru` — Redis автоматически удаляет старые записи о завершённых задачах при нехватке памяти вместо того, чтобы возвращать ошибки
- Проверка работоспособности: `redis-cli -a $REDIS_PASSWORD ping`
- Новый том `redis_data:`

Добавить `REDIS_PASSWORD` в `.env`.

### Определение сервиса Redis

```yaml
redis:
  image: redis:7-alpine
  container_name: n8n_redis
  restart: unless-stopped
  command: >
    redis-server
    --requirepass ${REDIS_PASSWORD}
    --appendonly yes
    --maxmemory 256mb
    --maxmemory-policy allkeys-lru
    --save 60 1
    --loglevel notice
  volumes:
    - redis_data:/data
  healthcheck:
    test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
    interval: 10s
    timeout: 5s
    retries: 5
  deploy:
    resources:
      limits:
        cpus: "0.5"
        memory: 384M
      reservations:
        cpus: "0.1"
        memory: 128M
  networks:
    - n8n_network
```

---

## Фаза 2 — Настройка режима очередей n8n

### Разделение ролей — ключевое архитектурное решение

В режиме очередей процессы n8n выполняют две различные роли:

**Основной экземпляр (Main)** — обслуживает UI редактора, REST API и приёмник вебхуков. Ставит задачи выполнения рабочих процессов в очередь Redis. Требует привязки сессий (sticky sessions) от nginx, чтобы WebSocket-соединение для push-уведомлений в браузере оставалось на том же экземпляре.

**Воркер (Worker)** — не имеет UI и не принимает вебхуки. Забирает задачи из очереди Bull в Redis и выполняет рабочие процессы. Масштабируется горизонтально. Никогда не добавляется в upstream nginx.

```
nginx (ip_hash — привязка сессий)
  ├── n8n1 (main) ─┐
  └── n8n2 (main) ─┼──► PostgreSQL
                   │
                  Redis (очередь Bull)
                   │
                   ├── n8n_worker_1 (воркер, НЕ в upstream nginx)
                   └── n8n_worker_2 (опционально)
```

### Новые переменные окружения для ВСЕХ экземпляров (основные + воркеры)

| Переменная | Значение |
|---|---|
| `EXECUTIONS_MODE` | `queue` |
| `QUEUE_BULL_REDIS_HOST` | `n8n_redis` |
| `QUEUE_BULL_REDIS_PORT` | `6379` |
| `QUEUE_BULL_REDIS_PASSWORD` | `${REDIS_PASSWORD}` |
| `QUEUE_BULL_REDIS_DB` | `0` |
| `QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD` | `10000` |

### Дополнительные переменные только для **основных** экземпляров

| Переменная | Значение |
|---|---|
| `N8N_PUSH_BACKEND` | `websocket` |

### Дополнительные переменные только для **воркеров**

| Переменная | Значение | Примечание |
|---|---|---|
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | `10` | Настроить под доступные CPU/RAM |
| `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS` | `true` | Тестовые запуски из редактора тоже отправляются на воркеры |

Воркеры используют `command: worker` в `docker-compose.yml` — это единственное, что переключает бинарник n8n в режим воркера.

### Определение сервиса воркера

```yaml
n8n_worker_1:
  build: .
  container_name: n8n_worker_1
  restart: unless-stopped
  command: worker
  environment:
    - EXECUTIONS_MODE=queue
    - QUEUE_BULL_REDIS_HOST=n8n_redis
    - QUEUE_BULL_REDIS_PORT=6379
    - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    - QUEUE_BULL_REDIS_DB=0
    - QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD=10000
    - DB_TYPE=postgresdb
    - DB_POSTGRESDB_HOST=PostgreSQL
    - DB_POSTGRESDB_PORT=5432
    - DB_POSTGRESDB_DATABASE=n8n
    - DB_POSTGRESDB_USER=${POSTGRES_USER:-postgres}
    - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD:-postgres}
    - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    - GENERIC_TIMEZONE=Europe/Moscow
    - N8N_DIAGNOSTICS_ENABLED=false
    - N8N_COMMUNITY_PACKAGES_ENABLED=true
    - DB_POSTGRESDB_POOL_SIZE=10
    - DB_POSTGRESDB_CONNECTION_TIMEOUT=30000
    - DB_POSTGRESDB_ACQUIRE_CONNECTION_TIMEOUT=60000
    - N8N_CONCURRENCY_PRODUCTION_LIMIT=10
    - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
    - N8N_METRICS=true
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy
  healthcheck:
    test: ["CMD-SHELL", "pgrep -f 'n8n worker' || exit 1"]
    interval: 30s
    timeout: 10s
    retries: 3
  deploy:
    resources:
      limits:
        cpus: "2.0"
        memory: 2G
      reservations:
        cpus: "0.5"
        memory: 1G
  networks:
    - n8n_network
```

---

## Фаза 3 — Мониторинг (Redis Exporter)

Добавить сервис `redis-exporter` в `docker-compose.yml`:

```yaml
redis-exporter:
  image: oliver006/redis_exporter:latest
  container_name: redis_exporter
  restart: unless-stopped
  environment:
    - REDIS_ADDR=redis://n8n_redis:6379
    - REDIS_PASSWORD=${REDIS_PASSWORD}
  depends_on:
    - redis
  networks:
    - n8n_network
```

### Добавить в `monitoring/prometheus/prometheus.yml`

```yaml
  - job_name: 'redis'
    static_configs:
      - targets: ['redis-exporter:9121']

  - job_name: 'n8n_workers'
    static_configs:
      - targets: ['n8n_worker_1:5678']
    metrics_path: /metrics
```

### Добавить в `monitoring/prometheus/alerts.yml`

```yaml
  - name: redis_alerts
    rules:
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        annotations:
          summary: "Redis недоступен"
          description: "Redis Exporter не может подключиться к Redis. Все поставленные в очередь выполнения n8n заблокированы."

      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.85
        for: 5m
        annotations:
          summary: "Использование памяти Redis превышает 85%"
          description: "Redis использует {{ $value | humanizePercentage }} от максимального объёма памяти. Политика вытеснения allkeys-lru активна."

      - alert: N8NQueueDepthHigh
        expr: sum(redis_list_length{key=~"bull:.*:waiting"}) > 100
        for: 5m
        annotations:
          summary: "В очереди выполнения n8n {{ $value }} ожидающих задач"
          description: "Глубина очереди высока. Рассмотрите добавление дополнительных воркеров."
```

Ключевые метрики, предоставляемые `redis_exporter`:
- `redis_connected_clients` — мониторинг утечек соединений
- `redis_memory_used_bytes` — отслеживание относительно лимита в 256 МБ
- `redis_keyspace_hits_total` / `redis_keyspace_misses_total` — эффективность кеша
- `redis_blocked_clients` — обнаружение зависаний очереди
- `redis_list_length{key="bull:*:waiting"}` — глубина каждой очереди Bull

---

## Фаза 4 — Порядок развёртывания (~60 сек простоя)

> **Перед шагом 3:** сделайте резервную копию PostgreSQL и убедитесь, что критически важные рабочие процессы не выполняются.

```bash
# 1. Сначала запустить Redis, проверить подключение
docker-compose up -d redis
docker-compose exec redis redis-cli -a "$REDIS_PASSWORD" ping
# Ожидаемый результат: PONG

# 2. Запустить Redis Exporter
docker-compose up -d redis-exporter

# 3. Остановить основные экземпляры n8n  ← начало простоя
docker-compose stop n8n1 n8n2

# 4. Применить все изменения конфигурации в docker-compose.yml и nginx.conf

# 5. Поднять основные экземпляры с новой конфигурацией режима очередей
docker-compose up -d n8n1 n8n2
# Дождаться статуса healthy:
docker-compose ps n8n1 n8n2

# 6. Поднять воркеры  ← конец простоя
docker-compose up -d n8n_worker_1

# 7. Перезагрузить конфигурацию nginx (горячая перезагрузка, без простоя)
docker-compose exec nginx nginx -s reload

# 8. Перезагрузить конфигурацию Prometheus
curl -X POST http://localhost:9090/-/reload
```

### Известные риски

**Перерегистрация активных вебхуков** — при перезапуске основных экземпляров с `EXECUTIONS_MODE=queue` n8n заново регистрирует все активные вебхуки рабочих процессов при запуске. Это занимает несколько секунд. Проверка работоспособности (health check) на n8n1/n8n2 задерживает трафик от nginx до завершения запуска.

**Потеря выполняемых задач** — все выполнения, работающие на момент шага 3, будут прерваны. Планируйте миграцию на часы с минимальной нагрузкой.

**Redis как единая точка отказа** — Redis теперь является жёсткой зависимостью. Если он упадёт, новые выполнения не смогут запуститься. Алерт `RedisDown` срабатывает в течение 1 минуты. Для повышения отказоустойчивости рассмотрите Redis Sentinel или управляемый сервис Redis.

**Несовпадение POSTGRES_DB (существующая проблема)** — значение по умолчанию в `.env` — `POSTGRES_DB=pgdb`, но экземпляры n8n используют `DB_POSTGRESDB_DATABASE=n8n`. Проверьте фактическое имя базы данных перед миграцией:
```bash
docker exec PostgreSQL psql -U pguser -l
```

---

## Фаза 5 — Чек-лист верификации

- [ ] `docker exec n8n_redis redis-cli -a "$REDIS_PASSWORD" keys "bull:*"` — ключи очереди Bull появляются после первого запуска рабочего процесса
- [ ] `docker-compose logs n8n_worker_1 --tail 20` — в логах видны строки `Executing job`
- [ ] Статус узлов в редакторе обновляется в реальном времени без перезагрузки страницы
- [ ] `docker-compose logs nginx | grep "101"` — видны HTTP 101 WebSocket-апгрейды
- [ ] `curl "http://localhost:9090/api/v1/query?query=redis_up"` — значение `1`
- [ ] Остановить `n8n2` во время выполнения — воркер всё равно завершает задачу (доказательство изоляции очереди)

---

## Сводка всех изменений в файлах

| Файл | Изменение |
|---|---|
| `docker-compose.yml` | Добавлены сервисы `redis`, `redis-exporter`, `n8n_worker_1`; переменные окружения режима очередей для n8n1/n8n2; том `redis_data`; обновлены `depends_on` |
| `nginx/nginx.conf` | Блок `map` + исправление `Connection $connection_upgrade` + `ip_hash` в upstream |
| `monitoring/prometheus/prometheus.yml` | Добавлены задачи сбора метрик (scrape jobs) `redis` и `n8n_workers` |
| `monitoring/prometheus/alerts.yml` | Добавлена группа алертов `redis_alerts` |
| `.env` | Добавлен `REDIS_PASSWORD` |
