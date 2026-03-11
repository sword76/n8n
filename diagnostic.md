## Пошаговая инструкция: диагностика и первичная настройка мониторинга для стека n8n

### Цель
После развертывания локальной системы n8n (два инстанса + Nginx + PostgreSQL) вы столкнулись с ошибками при запуске нод. В этом руководстве мы:
1. Проведем диагностику: проверим логи, связность между компонентами, доступность базы данных.
2. Настроим базовый мониторинг (Prometheus + Grafana + Alertmanager) для отслеживания состояния системы: доступность n8n, загрузка CPU/памяти, основные метрики.

Инструкция рассчитана на то, что у вас уже запущены контейнеры из `docker-compose.yml`, описанного ранее.

---

### Шаг 1. Диагностика проблемы

#### 1.1. Просмотр логов n8n-серверов
Выполните команды для просмотра логов каждого инстанса:
```bash
# Логи первого инстанса
docker logs n8n_instance_1 --tail 50

# Логи второго инстанса
docker logs n8n_instance_2 --tail 50
```
Ищите в выводе стек-трейсы ошибок, особенно связанные с подключением к базе данных или неверными переменными окружения.

#### 1.2. Проверка доступности n8n через Nginx
Сделайте запрос к балансировщику:
```bash
curl -I http://localhost
```
Ожидаемый ответ: `HTTP/1.1 200 OK` или `302 Found` (редирект на логин). Если ошибка, проверьте конфигурацию Nginx.

#### 1.3. Проверка health-эндпоинтов самих n8n
```bash
curl http://localhost:5678/healthz   # для первого (если проброшен порт)
curl http://localhost:5679/healthz   # для второго, если настроен проброс портов
```
Если порты не проброшены, используйте `docker exec`:
```bash
docker exec n8n_instance_1 curl http://localhost:5678/healthz
docker exec n8n_instance_2 curl http://localhost:5678/healthz
```
Ожидается `ok` или статус 200.

#### 1.4. Проверка подключения к PostgreSQL из контейнеров n8n
Зайдите в контейнер и выполните тестовый запрос:
```bash
docker exec -it n8n_instance_1 sh
# внутри контейнера:
apt-get update && apt-get install -y postgresql-client   # если нет psql
PGPASSWORD=your_password psql -h postgres -U n8n_user -d n8n -c "SELECT 1"
```
Если подключение не удается, проверьте:
- Совпадает ли имя хоста БД в переменных окружения (`DB_POSTGRESDB_HOST` должно быть `postgres` — имя сервиса в docker-compose).
- Существует ли база данных и пользователь.
- Настройки сети: контейнеры должны быть в одной сети (`n8n_network`).

#### 1.5. Проверка через DBeaver (внешний доступ к БД)
Если у вас есть доступ к контейнеру PostgreSQL через DBeaver:
- Хост: `localhost` (или IP), порт: `5432` (проброшен ли?).
- Убедитесь, что в `docker-compose.yml` для postgres проброшен порт, например:
  ```yaml
  ports:
    - "5432:5432"
  ```
- Используйте те же учетные данные для тестового запроса.

#### 1.6. Анализ ошибок
На основе полученных логов исправьте конфигурацию. Наиболее частая причина – неверные параметры подключения к БД. Убедитесь, что все переменные окружения в n8n заданы корректно.

---

### Шаг 2. Настройка сбора метрик (Prometheus)

#### 2.1. Добавление nginx-exporter
Убедитесь, что в вашем `docker-compose.yml` есть сервис `nginx-exporter` (как в предыдущем примере) и что в конфигурации Nginx открыт эндпоинт `/stub_status`.

Если его нет, добавьте:
```yaml
nginx-exporter:
  image: nginx/nginx-prometheus-exporter:latest
  container_name: nginx_exporter
  command: ['-nginx.scrape-uri=http://nginx:80/stub_status']
  networks:
    - n8n_network
```

#### 2.2. Создание конфигурации Prometheus
Создайте директорию `prometheus` и файл `prometheus/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - "alerts.yml"

scrape_configs:
  - job_name: 'n8n'
    static_configs:
      - targets: ['n8n_instance_1:5678', 'n8n_instance_2:5678']
    metrics_path: /metrics

  - job_name: 'nginx'
    static_configs:
      - targets: ['nginx-exporter:9113']
```

#### 2.3. Запуск Prometheus
Добавьте в `docker-compose.yml` сервис Prometheus (как было показано ранее) и перезапустите стек:
```bash
docker-compose up -d prometheus
```

Проверьте, что Prometheus собирает метрики: откройте http://localhost:9090/targets – все цели должны быть в состоянии UP.

---

### Шаг 3. Настройка визуализации (Grafana)

#### 3.1. Запуск Grafana
Убедитесь, что Grafana добавлена в `docker-compose.yml`:
```yaml
grafana:
  image: grafana/grafana:latest
  container_name: grafana
  environment:
    - GF_SECURITY_ADMIN_PASSWORD=admin
  ports:
    - "3000:3000"
  volumes:
    - grafana_data:/var/lib/grafana
  networks:
    - n8n_network
```
Запустите: `docker-compose up -d grafana`.

#### 3.2. Подключение Prometheus как источника данных
1. Откройте http://localhost:3000 (логин: admin, пароль: admin).
2. Перейдите в Configuration → Data Sources → Add data source.
3. Выберите Prometheus.
4. В поле URL введите `http://prometheus:9090`.
5. Нажмите Save & Test – должно быть зелёное сообщение.

#### 3.3. Импорт дашбордов
- Для n8n можно использовать готовый дашборд (например, ID 16247 на grafana.com).
- Для базовых метрик системы (CPU, память) можно импортировать дашборд Node Exporter Full (ID 1860), но у нас нет node-exporter. Пока создадим простой дашборд вручную.

#### 3.4. Создание простого дашборда для мониторинга n8n
1. Создайте новый дашборд.
2. Добавьте панель с запросом `up{job="n8n"}` – покажет, какие инстансы живы.
3. Добавьте панель с запросом `rate(process_cpu_seconds_total{job="n8n"}[1m])` – загрузка CPU.
4. Добавьте панель с `process_resident_memory_bytes{job="n8n"}` – используемая память.
5. Сохраните дашборд.

---

### Шаг 4. Настройка оповещений (Alertmanager)

#### 4.1. Конфигурация Alertmanager
Создайте файл `alertmanager/alertmanager.yml` (пример для Telegram):
```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'telegram'

receivers:
- name: 'telegram'
  telegram_configs:
  - bot_token: 'YOUR_BOT_TOKEN'
    chat_id: YOUR_CHAT_ID
    api_url: 'https://api.telegram.org'
    parse_mode: 'HTML'
```
Вместо Telegram можно использовать email, slack и др.

#### 4.2. Правила алертов (alerts.yml)
Создайте файл `prometheus/alerts.yml` рядом с `prometheus.yml`:
```yaml
groups:
- name: n8n_alerts
  rules:
  - alert: N8nInstanceDown
    expr: up{job="n8n"} == 0
    for: 1m
    annotations:
      summary: "Instance {{ $labels.instance }} is down"
  - alert: HighCpuUsage
    expr: rate(process_cpu_seconds_total{job="n8n"}[5m]) > 0.8
    for: 5m
    annotations:
      summary: "High CPU on {{ $labels.instance }}"
  - alert: HighMemoryUsage
    expr: process_resident_memory_bytes{job="n8n"} > 1e9
    for: 5m
    annotations:
      summary: "Memory > 1GB on {{ $labels.instance }}"
```

#### 4.3. Запуск Alertmanager
Добавьте в `docker-compose.yml`:
```yaml
alertmanager:
  image: prom/alertmanager:latest
  container_name: alertmanager
  volumes:
    - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
  ports:
    - "9093:9093"
  networks:
    - n8n_network
```
Запустите: `docker-compose up -d alertmanager`.

#### 4.4. Проверка
Перейдите в http://localhost:9093 – увидите интерфейс Alertmanager. Чтобы проверить алерты, можно временно остановить один из n8n-контейнеров и через минуту убедиться, что алерт появился в Prometheus (http://localhost:9090/alerts) и был отправлен в Telegram.

---

### Шаг 5. (Опционально) Сбор логов с помощью Loki и Promtail

Если требуется централизованный сбор логов (а не только метрик), можно добавить стек Loki + Promtail.

#### 5.1. Добавление Loki
В `docker-compose.yml` добавьте:
```yaml
loki:
  image: grafana/loki:latest
  container_name: loki
  ports:
    - "3100:3100"
  command: -config.file=/etc/loki/local-config.yaml
  networks:
    - n8n_network

promtail:
  image: grafana/promtail:latest
  container_name: promtail
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ./promtail/promtail-config.yaml:/etc/promtail/config.yaml
  command: -config.file=/etc/promtail/config.yaml
  networks:
    - n8n_network
```

#### 5.2. Конфигурация Promtail
Создайте `promtail/promtail-config.yaml`:
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    static_configs:
      - targets: ['localhost']
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*-json.log
```

#### 5.3. Подключение Loki в Grafana
В Grafana добавьте источник данных Loki (URL: http://loki:3100). Теперь можно просматривать логи контейнеров прямо в Grafana (Explore).

---

### Заключение
После выполнения этих шагов вы получите:
- Работающую систему n8n (после исправления ошибок).
- Сбор метрик с n8n и Nginx в Prometheus.
- Визуализацию ключевых показателей в Grafana.
- Оповещения о критических событиях через Alertmanager.
- (Опционально) Централизованный сбор логов через Loki.

Теперь вы можете уверенно эксплуатировать систему и быстро реагировать на сбои.

---

## Приложение: Полезные команды для диагностики
```bash
# Проверка логов всех контейнеров
docker-compose logs --tail=50 -f

# Проверка состояния контейнеров
docker-compose ps

# Перезапуск конкретного сервиса
docker-compose restart n8n1

# Подключение к базе данных из контейнера
docker exec -it n8n_postgres psql -U n8n_user -d n8n

# Тест подключения n8n к БД из контейнера
docker exec n8n_instance_1 curl -f http://localhost:5678/healthz
```

**Важно:** Убедитесь, что в переменных окружения n8n указан правильный пароль и имя хоста БД (`postgres`). После изменения переменных перезапустите контейнеры.

---

Если у вас остались вопросы, создайте issue в репозитории или обратитесь к документации:
- [n8n Documentation](https://docs.n8n.io/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)