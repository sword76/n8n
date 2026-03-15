# Redis + n8n Queue Mode — Implementation Plan

## Phase 0 — Pre-work (Critical Bugs First)

| # | File | Fix |
|---|---|---|
| 1 | `nginx/nginx.conf` | Add `map $http_upgrade $connection_upgrade` block; replace `Connection "upgrade"` → `Connection $connection_upgrade` |
| 2 | `nginx/nginx.conf` | Add `ip_hash;` to upstream (for sticky editor sessions) |

---

## Phase 1 — Add Redis

Add a `redis` service to `docker-compose.yml`:
- Image: `redis:7-alpine`
- AOF persistence (`appendonly yes`) — loses at most 1 second of data on crash vs. minutes with RDB
- Password-protected via `${REDIS_PASSWORD}`
- `maxmemory 256mb` + `allkeys-lru` eviction policy — Redis self-evicts old completed job records under memory pressure instead of returning errors
- Health check: `redis-cli -a $REDIS_PASSWORD ping`
- New `redis_data:` volume

Add `REDIS_PASSWORD` to `.env`.

### Redis service definition

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

## Phase 2 — Configure n8n Queue Mode

### Role split — key architectural decision

In Queue Mode, n8n processes have two distinct roles:

**Main** — runs the editor UI, REST API, and webhook receiver. Enqueues workflow jobs to Redis. Must have sticky sessions from nginx so the browser's WebSocket push connection stays on the same instance.

**Worker** — has no UI and no webhook listener. Pulls jobs from the Redis Bull queue and executes workflows. Can be scaled horizontally. Never added to the nginx upstream.

```
nginx (ip_hash sticky)
  ├── n8n1 (main) ─┐
  └── n8n2 (main) ─┼──► PostgreSQL
                   │
                  Redis (Bull queue)
                   │
                   ├── n8n_worker_1 (worker, NOT in nginx upstream)
                   └── n8n_worker_2 (optional)
```

### New environment variables for ALL instances (main + worker)

| Variable | Value |
|---|---|
| `EXECUTIONS_MODE` | `queue` |
| `QUEUE_BULL_REDIS_HOST` | `n8n_redis` |
| `QUEUE_BULL_REDIS_PORT` | `6379` |
| `QUEUE_BULL_REDIS_PASSWORD` | `${REDIS_PASSWORD}` |
| `QUEUE_BULL_REDIS_DB` | `0` |
| `QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD` | `10000` |

### Additional variables for **main** instances only

| Variable | Value |
|---|---|
| `N8N_PUSH_BACKEND` | `websocket` |

### Additional variables for **worker** instances only

| Variable | Value | Note |
|---|---|---|
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | `10` | Tune to available CPU/RAM |
| `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS` | `true` | Editor "test runs" also go to workers |

Workers use `command: worker` in `docker-compose.yml` — this is the only thing that switches the n8n binary into worker mode.

### Worker service definition

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

## Phase 3 — Monitoring (Redis Exporter)

Add `redis-exporter` service to `docker-compose.yml`:

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

### Add to `monitoring/prometheus/prometheus.yml`

```yaml
  - job_name: 'redis'
    static_configs:
      - targets: ['redis-exporter:9121']

  - job_name: 'n8n_workers'
    static_configs:
      - targets: ['n8n_worker_1:5678']
    metrics_path: /metrics
```

### Add to `monitoring/prometheus/alerts.yml`

```yaml
  - name: redis_alerts
    rules:
      - alert: RedisDown
        expr: redis_up == 0
        for: 1m
        annotations:
          summary: "Redis is down"
          description: "Redis exporter cannot reach Redis. All n8n queued executions are blocked."

      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.85
        for: 5m
        annotations:
          summary: "Redis memory above 85%"
          description: "Redis is at {{ $value | humanizePercentage }} of max memory. allkeys-lru eviction is active."

      - alert: N8NQueueDepthHigh
        expr: sum(redis_list_length{key=~"bull:.*:waiting"}) > 100
        for: 5m
        annotations:
          summary: "n8n execution queue has {{ $value }} waiting jobs"
          description: "Queue depth is high. Consider adding more worker instances."
```

Key metrics exposed by `redis_exporter`:
- `redis_connected_clients` — monitor for connection leaks
- `redis_memory_used_bytes` — track against the 256MB limit
- `redis_keyspace_hits_total` / `redis_keyspace_misses_total` — cache efficiency
- `redis_blocked_clients` — detect queue stalls
- `redis_list_length{key="bull:*:waiting"}` — queue depth per Bull queue

---

## Phase 4 — Rollout Order (~60 sec downtime)

> **Before step 3:** take a PostgreSQL backup and verify no critical workflows are running.

```bash
# 1. Start Redis first, verify connectivity
docker-compose up -d redis
docker-compose exec redis redis-cli -a "$REDIS_PASSWORD" ping
# Expected: PONG

# 2. Start Redis exporter
docker-compose up -d redis-exporter

# 3. Stop n8n main instances  ← downtime starts
docker-compose stop n8n1 n8n2

# 4. Apply all config changes to docker-compose.yml and nginx.conf

# 5. Bring up main instances with new Queue Mode config
docker-compose up -d n8n1 n8n2
# Wait for healthy status:
docker-compose ps n8n1 n8n2

# 6. Bring up workers  ← downtime ends
docker-compose up -d n8n_worker_1

# 7. Reload nginx config (live reload, zero downtime)
docker-compose exec nginx nginx -s reload

# 8. Reload Prometheus config
curl -X POST http://localhost:9090/-/reload
```

### Known risks

**Active webhooks re-registration** — when main instances restart with `EXECUTIONS_MODE=queue`, n8n re-registers all active workflow webhooks on startup. This takes a few seconds. The healthcheck on n8n1/n8n2 delays nginx traffic until startup completes.

**In-flight executions lost** — any executions running at step 3 will be interrupted. Schedule the migration during low-traffic hours.

**Redis single point of failure** — Redis is now a hard dependency. If it dies, no new executions can start. The `RedisDown` alert fires within 1 minute. For higher availability, consider Redis Sentinel or a managed Redis service.

**POSTGRES_DB mismatch (pre-existing)** — the `.env` default is `POSTGRES_DB=pgdb` but n8n instances use `DB_POSTGRESDB_DATABASE=n8n`. Verify the actual database name before migration:
```bash
docker exec PostgreSQL psql -U pguser -l
```

---

## Phase 5 — Verification Checklist

- [ ] `docker exec n8n_redis redis-cli -a "$REDIS_PASSWORD" keys "bull:*"` — Bull queue keys appear after first workflow trigger
- [ ] `docker-compose logs n8n_worker_1 --tail 20` — shows `Executing job` log lines
- [ ] Editor node status updates in real-time without page refresh
- [ ] `docker-compose logs nginx | grep "101"` — HTTP 101 WebSocket upgrades visible
- [ ] `curl "http://localhost:9090/api/v1/query?query=redis_up"` — value `1`
- [ ] Stop `n8n2` mid-execution — worker completes the job anyway (queue isolation proof)

---

## Summary of All File Changes

| File | Change |
|---|---|
| `docker-compose.yml` | Add `redis`, `redis-exporter`, `n8n_worker_1` services; Queue Mode env vars on n8n1/n8n2; `redis_data` volume; updated `depends_on` |
| `nginx/nginx.conf` | `map` block + `Connection $connection_upgrade` fix + `ip_hash` in upstream |
| `monitoring/prometheus/prometheus.yml` | Add `redis` and `n8n_workers` scrape jobs |
| `monitoring/prometheus/alerts.yml` | Add `redis_alerts` group |
| `.env` | Add `REDIS_PASSWORD` |
