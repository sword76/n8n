# Проект отказоустойчивого развертывания n8n с балансировкой и мониторингом

Данный проект представляет собой комплексное решение для запуска двух экземпляров **n8n** (платформы для автоматизации рабочих процессов) с балансировкой нагрузки через **Nginx**, общей базой данных **PostgreSQL**, а также полноценным мониторингом на базе **Prometheus**, **Grafana** и **Alertmanager**.  

Основная цель — обеспечить высокую доступность, масштабируемость и наблюдаемость системы. В рамках проекта описан процесс локального развертывания (на собственном сервере или виртуальной машине) и последующей миграции в облако **Yandex Cloud** с использованием управляемой БД (Managed Service for PostgreSQL) и организацией резервного копирования на **AWS S3**.

---
**⏱ Время на чтение:** ~5 минут  
**⚙️ Время на реализацию:** В зависимости от опыта

---

## 1. Развертывание на локальном ресурсе

Перед миграцией в облако необходимо развернуть и отладить систему локально. Это позволяет проверить работоспособность всех компонентов и подготовить конфигурации.

### 1.1. Docker

Для контейнеризации используется **Docker** и **Docker Compose**. Убедитесь, что на вашей машине установлены:
- Docker (версия 20.10+)
- Docker Compose (версия 2.x)

Создайте файл `docker-compose.yml` со следующим содержимым (ключевые сервисы: n8n1, n8n2, nginx):

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=n8n
      - POSTGRES_USER=n8n_user
      - POSTGRES_PASSWORD=your_local_password
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n_user -d n8n"]
      interval: 30s
      timeout: 10s
      retries: 5
    networks:
      - n8n_network

  n8n1:
    image: n8nio/n8n:latest
    container_name: n8n_instance_1
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=your_local_password
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://localhost:80
      - GENERIC_TIMEZONE=Europe/Moscow
      - N8N_METRICS=true
    volumes:
      - n8n_data1:/home/node/.n8n
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - n8n_network

  n8n2:
    image: n8nio/n8n:latest
    container_name: n8n_instance_2
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n_user
      - DB_POSTGRESDB_PASSWORD=your_local_password
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://localhost:80
      - GENERIC_TIMEZONE=Europe/Moscow
      - N8N_METRICS=true
    volumes:
      - n8n_data2:/home/node/.n8n
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - n8n_network

  nginx:
    image: nginx:alpine
    container_name: n8n_nginx_lb
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
    depends_on:
      - n8n1
      - n8n2
    networks:
      - n8n_network

volumes:
  pg_data:
  n8n_data1:
  n8n_data2:

networks:
  n8n_network:
    driver: bridge
```

Не забудьте создать файл конфигурации Nginx с настройками upstream для двух инстансов n8n и включить `stub_status` для сбора метрик.

```nginx
events {
    worker_connections 1024;
}

http {
    upstream n8n_backend {
        least_conn;
        server n8n_instance_1:5678;
        server n8n_instance_2:5678;
    }

    server {
        listen 80;
        server_name localhost;

        location / {
            proxy_pass http://n8n_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        location /stub_status {
            stub_status;
            allow 127.0.0.1;
            allow 172.16.0.0/12;
            deny all;
        }
    }
}
```

### 1.2. PostgreSQL

В локальной среде можно запустить PostgreSQL также в контейнере или использовать уже работающий экземпляр. Для совместимости с будущей облачной БД используйте PostgreSQL версии 15.

Пример запуска через Docker Compose:

```yaml
postgres:
  image: postgres:15
  environment:
    POSTGRES_DB: n8n
    POSTGRES_USER: n8n_user
    POSTGRES_PASSWORD: your_password
  volumes:
    - pg_data:/var/lib/postgresql/data
```

Перед первым запуском n8n необходимо создать базу данных и пользователя (если они не были созданы автоматически).

### 1.3. Мониторинг

Стек мониторинга включает:

- **Prometheus** — сбор метрик с n8n (эндпоинт `/metrics`) и Nginx (через `nginx-exporter`).
- **Grafana** — визуализация дашбордов.
- **Alertmanager** — отправка уведомлений при срабатывании правил.

Добавьте в `docker-compose.yml` сервисы мониторинга:

```yaml
  nginx-exporter:
    image: nginx/nginx-prometheus-exporter:latest
    container_name: nginx_exporter
    restart: unless-stopped
    command: ['-nginx.scrape-uri=http://nginx:80/stub_status']
    networks:
      - n8n_network

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
    ports:
      - "9090:9090"
    networks:
      - n8n_network

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on:
      - prometheus
    networks:
      - n8n_network

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
      - alertmanager_data:/alertmanager
    ports:
      - "9093:9093"
    networks:
      - n8n_network

volumes:
  prometheus_data:
  grafana_data:
  alertmanager_data:
```

Создайте файл `prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s

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

---

## 2. Перенос на хостинг

После успешной локальной эксплуатации наступает этап миграции в облако. Мы выбрали **Yandex Cloud** по ряду причин, описанных ниже.

### 2.1. Сравнительный анализ провайдеров: Yandex Cloud vs Selectel vs Beget

### Методология сравнения
Для объективной оценки я использовал критерии, критически важные для нашего проекта с n8n: наличие управляемых баз данных (PostgreSQL), возможность мониторинга, стоимость типовой конфигурации (4 vCPU, 8 GB RAM, 50 GB SSD), программы лояльности для стартапов и качество инфраструктуры.

### Детальное сравнение по ключевым параметрам

| Критерий | **Yandex Cloud** | **Selectel** | **Beget** |
|----------|------------------|--------------|-----------|
| **Тип платформы** | Полноценная облачная платформа (IaaS/PaaS) | Крупный провайдер с фокусом на Enterprise | Хостинг-провайдер с развивающимся облаком  |
| **Управляемые БД (DBaaS)** | ✅ PostgreSQL, MySQL, Redis, MongoDB, ClickHouse  | ✅ PostgreSQL, MySQL, Redis, TimescaleDB, Kafka  | ✅ PostgreSQL, MySQL (базовые возможности)  |
| **Мониторинг (Prometheus/Grafana)** | ✅ Полная интеграция, Managed Grafana | ✅ Через Cloud Monitoring или самостоятельная настройка | ⚠️ Базовая статистика, требуется ручная настройка |
| **Объектное хранилище (S3)** | Yandex Object Storage (920 баллов в рейтинге CNews)  | **Лидер рейтинга (1035 баллов)** — мультирегиональность, высокая надежность  | ✅ Beget S3 — базовая функциональность  |
| **Kubernetes** | ✅ Managed Kubernetes | ✅ Managed Kubernetes | 🔄 В разработке (запуск в 2026)  |
| **ЦОДы и инфраструктура** | 3 зоны доступности в РФ, Tier III | 5 собственных ЦОДов Tier III в РФ  | Tier III в РФ, Казахстане, Латвии  |
| **SLA (доступность)** | 99.95% и выше | 99.95% для БД | 99.98% для VDS  |
| **Стоимость типовой ВМ (4vCPU, 8GB RAM, 50GB SSD)** | ~5 500-6 500 ₽/мес (PAYG)  | ~8 500-10 000 ₽/мес  | **~3 000-4 000 ₽/мес** (минимальная конфигурация от 210 ₽)  |
| **Программа для стартапов** | **Гранты до 2 млн ₽**  | **Кешбэк 30%** (до 1 млн бонусов)  | **Гранты до 1.5 млн ₽** на год  |
| **Бесплатные бэкапы** | Да, в Managed Services | Да, для managed БД | ✅ **На всех тарифах VDS**  |
| **Панель управления** | Техничная, для профессионалов | Функциональная, корпоративная | **Собственная разработка**, очень удобная для новичков  |
| **Техподдержка** | 24/7, среднее время реакции | 24/7, экспертная | **15 минут в Telegram**  |
| **Бесплатная миграция** | Ограниченно | Есть | ✅ **Полностью берут на себя**  |

### Плюсы и минусы каждого провайдера

#### ✅ **Yandex Cloud**
**Плюсы:**
- Самая богатая экосистема managed-сервисов
- Высокие гранты для стартапов (до 2 млн ₽) 
- Интеграция с другими сервисами Яндекса
- CVoS — скидки за резервирование до 22%

**Минусы:**
- Сложная настройка сетевого доступа
- Порог входа выше, чем у хостингов
- Ограничители производительности на некоторых тарифах

#### ✅ **Selectel**
**Плюсы:**
- **Лучшее S3-хранилище** в РФ 
- Надежная Enterprise-инфраструктура
- Широкий выбор managed БД 
- Программа кешбэка 30% 

**Минусы:**
- **Самая высокая стоимость** среди троих
- Меньше стартап-ориентированных программ
- Сложный интерфейс для начинающих

#### ✅ **Beget**
**Плюсы:**
- **Лучшее соотношение цена/качество** 
- Очень удобная панель управления 
- Бесплатные бэкапы на всех тарифах 
- Бесплатная миграция "под ключ" 
- Быстрая поддержка в Telegram 
- Гранты до 1.5 млн ₽ 

**Минусы:**
- Меньше managed-сервисов (нет Kafka, нет Managed Grafana)
- Kubernetes только в разработке 
- Меньше опыта в сложных enterprise-проектах

### Итоговый выбор: **Yandex Cloud** (с альтернативами)

Для нашего проекта с n8n, PostgreSQL и полноценным мониторингом я рекомендую **Yandex Cloud** по следующим причинам:

1. **Полноценный Managed Service for PostgreSQL** с автоматическим failover и пулером соединений
2. **Возможность настройки мониторинга** через Managed Grafana или интеграцию с Prometheus
3. **Высокие гранты** для стартапов до 2 млн ₽ 
4. **Объектное хранилище S3** для бэкапов с хорошей репутацией 
5. **Гибкая система скидок** CVoS для долгосрочной экономии

**Альтернативные варианты:**
- **Beget** — если бюджет ограничен, нужна простая миграция и не требуются сложные managed-сервисы (отличный выбор для MVP) 
- **Selectel** — если критически важны максимальная надежность S3, Enterprise-поддержка и вы готовы платить больше 

---

## 3. Миграция в Yandex Cloud

### 3.1. Подготовка инфраструктуры через Terraform

Создайте структуру директорий:

```bash
mkdir -p terraform/{network,vm,postgresql} config/{nginx,prometheus,grafana,alertmanager} scripts
```

**Файл: `terraform/main.tf`**
```hcl
terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
      version = ">= 0.130.0"
    }
  }
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = var.yc_zone
}
```

**Файл: `terraform/variables.tf`**
```hcl
variable "yc_token" {
  description = "Yandex Cloud OAuth token"
  type        = string
  sensitive   = true
}

variable "yc_cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

variable "yc_folder_id" {
  description = "Yandex Cloud Folder ID"
  type        = string
}

variable "yc_zone" {
  description = "Availability zone"
  default     = "ru-central1-a"
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}
```

**Файл: `terraform/network.tf`**
```hcl
resource "yandex_vpc_network" "n8n_network" {
  name = "n8n-network"
}

resource "yandex_vpc_subnet" "public" {
  name           = "public-subnet"
  zone           = var.yc_zone
  network_id     = yandex_vpc_network.n8n_network.id
  v4_cidr_blocks = ["10.10.1.0/24"]
}
```

**Файл: `terraform/postgresql.tf`**
```hcl
resource "yandex_mdb_postgresql_cluster" "n8n_db" {
  name        = "n8n-postgres-cluster"
  environment = "PRODUCTION"
  network_id  = yandex_vpc_network.n8n_network.id

  config {
    version = "15"
    resources {
      resource_preset_id = "s2.micro"  # 2 vCPU, 8 GB RAM
      disk_type_id       = "network-ssd"
      disk_size          = 50
    }
  }

  host {
    zone      = var.yc_zone
    name      = "n8n-db-master"
    subnet_id = yandex_vpc_subnet.public.id
    assign_public_ip = true
  }

  host {
    zone      = var.yc_zone
    name      = "n8n-db-replica"
    subnet_id = yandex_vpc_subnet.public.id
    assign_public_ip = true
  }
}

resource "yandex_mdb_postgresql_user" "n8n_user" {
  cluster_id = yandex_mdb_postgresql_cluster.n8n_db.id
  name       = "n8n_user"
  password   = var.db_password
}

resource "yandex_mdb_postgresql_database" "n8n_db" {
  cluster_id = yandex_mdb_postgresql_cluster.n8n_db.id
  name       = "n8n"
  owner      = yandex_mdb_postgresql_user.n8n_user.name
}
```

**Файл: `terraform/vm.tf`**
```hcl
resource "yandex_compute_image" "ubuntu" {
  source_family = "ubuntu-2204-lts"
}

resource "yandex_compute_instance" "n8n_vm" {
  name        = "n8n-app-server"
  platform_id = "standard-v3"
  zone        = var.yc_zone

  resources {
    cores  = 4
    memory = 8
    core_fraction = 100
  }

  boot_disk {
    initialize_params {
      image_id = yandex_compute_image.ubuntu.id
      size     = 100
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.public.id
    nat       = true
  }

  metadata = {
    user-data = <<-EOF
      #cloud-config
      users:
        - name: ubuntu
          sudo: ['ALL=(ALL) NOPASSWD:ALL']
          groups: sudo
      packages:
        - docker.io
        - docker-compose
        - postgresql-client
        - prometheus
        - grafana
      runcmd:
        - systemctl enable docker
        - systemctl start docker
        - usermod -aG docker ubuntu
    EOF
  }
}
```

**Файл: `terraform/outputs.tf`**
```hcl
output "vm_public_ip" {
  value = yandex_compute_instance.n8n_vm.network_interface.0.nat_ip_address
}

output "postgresql_master_fqdn" {
  value = yandex_mdb_postgresql_cluster.n8n_db.host[0].fqdn
}

output "connection_string" {
  value     = "postgresql://n8n_user:${var.db_password}@${yandex_mdb_postgresql_cluster.n8n_db.host[0].fqdn}:6432/n8n?sslmode=require"
  sensitive = true
}
```
### 3.2. Перенос базы данных

Создайте скрипт `scripts/migrate-data.sh`:

```bash
#!/bin/bash
set -e

source ../.env

DUMP_FILE="n8n_dump_$(date +%Y%m%d_%H%M%S).sql"

# Скачивание сертификата Yandex
wget -q "https://storage.yandexcloud.net/cloud-certs/CA.pem" -O ../certs/YandexCA.pem

# Создание дампа локальной БД
export PGPASSWORD="$LOCAL_PG_PASSWORD"
pg_dump -h localhost -U postgres -d n8n --format=custom -f "$DUMP_FILE"

# Восстановление в Yandex Cloud
export PGPASSWORD="$YANDEX_PG_PASSWORD"
pg_restore -h "$YANDEX_PG_HOST" -p 6432 -U n8n_user -d n8n \
  --clean --if-exists --no-owner \
  --set=sslmode=require --set=sslrootcert=../certs/YandexCA.pem "$DUMP_FILE"

echo "Migration completed!"
```

### 3.3. Перенос сервисов

Создайте скрипт `scripts/deploy-stack.sh`:

```bash
#!/bin/bash
set -e

VM_IP=$(terraform -chdir=../terraform output -raw vm_public_ip)

# Копирование файлов
scp ../docker-compose.yml ../.env ubuntu@$VM_IP:~/ 
scp -r ../config ubuntu@$VM_IP:~/ 
scp ../certs/YandexCA.pem ubuntu@$VM_IP:~/certs/

# Запуск стека
ssh ubuntu@$VM_IP "cd ~ && docker-compose up -d"

echo "Stack deployed! Access n8n at http://$VM_IP"
```

### 3.4. Тестирование

После развертывания выполните проверки:

```bash
# Проверка доступности n8n
curl -I http://$VM_IP

# Проверка метрик Prometheus
curl http://$VM_IP:9090/targets

# Проверка Grafana
curl http://$VM_IP:3000

# Тест workflow в n8n (создайте тестовый сценарий)
```

### 3.5. Мониторинг

Настройте дашборды в Grafana:

1. Подключите источник данных Prometheus (`http://prometheus:9090`)
2. Импортируйте дашборд для n8n (ID можно найти на grafana.com)
3. Настройте оповещения в Alertmanager

Пример `alertmanager/alertmanager.yml` для Telegram:

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: 'telegram'

receivers:
  - name: 'telegram'
    telegram_configs:
      - bot_token: 'YOUR_BOT_TOKEN'
        chat_id: YOUR_CHAT_ID
```

### 3.6. Организация Backup на AWS S3

Создайте скрипт `scripts/backup-to-s3.sh`:

```bash
#!/bin/bash
set -e

# Конфигурация
BACKUP_DIR="/tmp/n8n-backups"
DATE=$(date +%Y%m%d_%H%M%S)
BUCKET="n8n-backups"

mkdir -p $BACKUP_DIR

# Бэкап БД
docker exec n8n_postgres pg_dump -U n8n_user n8n > $BACKUP_DIR/n8n_db_$DATE.sql

# Бэкап конфигураций
tar -czf $BACKUP_DIR/n8n_configs_$DATE.tar.gz /home/ubuntu/n8n-stack/config/

# Загрузка в S3 (AWS или совместимое хранилище)
aws s3 cp $BACKUP_DIR/n8n_db_$DATE.sql s3://$BUCKET/db/
aws s3 cp $BACKUP_DIR/n8n_configs_$DATE.tar.gz s3://$BUCKET/configs/

# Очистка старых бэкапов (7 дней)
find $BACKUP_DIR -type f -mtime +7 -delete

# Удаленная очистка в S3 (30 дней)
aws s3 ls s3://$BUCKET/db/ | while read -r line; do
  createDate=$(echo $line | awk '{print $1" "$2}')
  createDate=$(date -d "$createDate" +%s)
  olderThan=$(date -d "30 days ago" +%s)
  if [[ $createDate -lt $olderThan ]]; then
    fileName=$(echo $line | awk '{print $4}')
    aws s3 rm s3://$BUCKET/db/$fileName
  fi
done

echo "Backup completed at $(date)"
```

Добавьте задание в crontab:

```bash
0 2 * * * /home/ubuntu/n8n-stack/scripts/backup-to-s3.sh >> /var/log/n8n-backup.log 2>&1
```

---

## 4. Ролевая модель и управление доступом

### 4.1. Роли в системе n8n

| Роль | Обязанности | Права доступа |
|------|-------------|---------------|
| **Пользователь** | Создание и запуск рабочих процессов | Доступ к веб-интерфейсу, управление своими workflows |
| **Администратор n8n** | Управление пользователями, глобальные настройки | Полный доступ ко всем функциям n8n |

### 4.2. Роли в PostgreSQL

| Роль | Обязанности | Права доступа |
|------|-------------|---------------|
| **Администратор БД** | Настройка параметров, мониторинг, бэкапы | Суперпользователь |
| **Приложение (n8n)** | Чтение/запись данных | Пользователь БД с правами на схему `public` |

### 4.3. Роли в инфраструктуре

| Роль | Обязанности | Права доступа |
|------|-------------|---------------|
| **DevOps-инженер** | Развертывание, поддержка, мониторинг | SSH к ВМ, доступ к Yandex Cloud (роль `editor`) |
| **Администратор безопасности** | SSL-сертификаты, firewall, IAM | Управление секретами, аудит |

### 4.4. Роли в мониторинге

| Роль | Обязанности | Права доступа |
|------|-------------|---------------|
| **Администратор мониторинга** | Настройка Prometheus, Alertmanager | Доступ к конфигам, перезагрузка сервисов |
| **Редактор Grafana** | Создание дашбордов | Редактирование, добавление источников |
| **Зритель** | Просмотр дашбордов | Только чтение |

### 4.5. Матрица доступа

| Сотрудник | n8n UI | PostgreSQL | ВМ (SSH) | Yandex Cloud | Grafana | Бэкапы (S3) |
|-----------|--------|------------|----------|--------------|---------|-------------|
| Пользователь | ✔️ чтение/запись своих процессов | – | – | – | – | – |
| Администратор n8n | ✔️ полный | – | – | – | – | – |
| DevOps-инженер | – | ✔️ (через приложение) | ✔️ | ✔️ (`editor`) | ✔️ (admin) | ✔️ (чтение/запись) |
| DBA | – | ✔️ (SQL) | – | – | ✔️ (viewer) | ✔️ (чтение) |
| Аудитор | – | – | – | ✔️ (`auditor`) | ✔️ (viewer) | ✔️ (чтение) |

---

## 5. Заключение и рекомендации

### 5.1. Итоги

Проект успешно реализует:
- Локальное развертывание отказоустойчивого стека n8n
- Миграцию в облако Yandex Cloud с минимальным даунтаймом
- Полный мониторинг через Prometheus/Grafana
- Автоматическое резервное копирование в S3
- Четкое разграничение прав доступа

### 5.2. Рекомендации по выбору провайдера

| Сценарий | Рекомендуемый провайдер | Обоснование |
|----------|------------------------|-------------|
| **Production с managed БД и мониторингом** | **Yandex Cloud** | Лучший набор managed-сервисов, гранты  |
| **MVP с ограниченным бюджетом** | **Beget** | Низкая цена, бесплатная миграция, бэкапы  |
| **Enterprise с высокими требованиями к S3** | **Selectel** | Лидер по S3, надежность  |

### 5.3. Дальнейшие шаги

1. **Масштабирование** — при росте нагрузки добавьте новые инстансы n8n
2. **Kubernetes** — рассмотрите переход на Managed Kubernetes в Yandex Cloud
3. **GDPR/152-ФЗ** — настройте соответствие требованиям
4. **Автоматизация** — внедрите CI/CD через GitLab CI или GitHub Actions

---

## Приложение: Полезные команды

```bash
# Локальный запуск
docker-compose up -d

# Просмотр логов
docker-compose logs -f

# Остановка
docker-compose down

# Подключение к БД
docker exec -it n8n_postgres psql -U n8n_user -d n8n

# Применение Terraform
cd terraform && terraform apply

# Получение IP ВМ
terraform output vm_public_ip
```

---

## Заключение

Данный проект демонстрирует полный цикл: от локальной разработки до промышленной эксплуатации в облаке с использованием современных подходов DevOps. Все компоненты максимально автоматизированы, что позволяет быстро восстанавливать систему после сбоев и масштабировать её по мере роста нагрузки.

Репозиторий содержит все необходимые файлы:
- `docker-compose.yml` — для локального запуска.
- `terraform/` — для развёртывания инфраструктуры в Yandex Cloud.
- `scripts/` — для миграции данных, развёртывания и бэкапов.
- `config/` — конфигурации Nginx, Prometheus, Grafana, Alertmanager.
- `.env.example` — шаблон переменных окружения.

Приятного использования! Если у вас возникнут вопросы или предложения, создавайте issue или pull request.

*Документ обновлен с учетом актуальных тарифов и возможностей провайдеров на начало 2026 года .*