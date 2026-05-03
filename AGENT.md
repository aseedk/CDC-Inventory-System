# AGENT.md — E-Commerce Inventory Live Sync (CDC)
> This file governs how AI agents and developers interact with this repository.
> Read it fully before writing any code, creating any file, or running any command.

---

## Project Overview

This project builds a **real-time Change Data Capture (CDC) pipeline** for an e-commerce inventory system. When a record changes in the source PostgreSQL database, that change must be captured, validated, and propagated to the target database and lakehouse layer within **500ms end-to-end**.

**Dataset**: Olist Brazilian E-Commerce (Kaggle) — 100,000+ orders across 9 relational tables.
**Stress test dataset**: Instacart (3M orders) — used for high-volume load testing only.

---

## Architecture Summary

```
PostgreSQL Source (WAL)
        │
        ▼
CDC Reader (Go) ──registers schema──▶ Redpanda Schema Registry
        │
        ▼  [Avro events]
Redpanda Topics (cdc.orders, cdc.order_items, cdc.products, ...)
        │
        ├──▶ Inventory Sync (Go) ──▶ PostgreSQL Target ──▶ Grafana
        │              │
        │              └──▶ Iceberg Writer ──▶ MinIO (Parquet)
        │
        └──▶ Dead-Letter Topic (cdc.dlq) — breaking schema changes
                       │
                       ▼
              Orchestrator (Go) ◀── polls /healthz on all services
                       │
                       ▼
              Kubernetes API (pod restart / alert)
```

**Six architectural layers:**
| Layer | Technology | Purpose |
|---|---|---|
| Source | PostgreSQL (port 5432) + WAL | CDC origin, logical replication |
| Streaming | Redpanda (port 9092) + Schema Registry (port 8084) | Avro event bus, schema versioning |
| Lakehouse | Apache Iceberg + MinIO (port 9000/9001) | Parquet storage, ACID, time-travel |
| Serving | PostgreSQL Target (port 5433) | Read-optimised, Grafana data source |
| Orchestration | Go Orchestrator (port 8083) + Kubernetes | Health probes, auto-restart, alerting |
| Visualization | Grafana (port 3000) + Prometheus (port 9090) | Dashboards + infrastructure metrics |

---

## Repository Structure

```
/
├── AGENT.md                        # This file
├── README.md                       # Human-readable project overview
├── docker-compose.yml              # Local development environment
├── helm/                           # Helm charts for all services
│   ├── Chart.yaml
│   ├── values.yaml                 # Default values (local)
│   ├── values-cloud.yaml           # Override values for cloud deployment
│   └── templates/
│       ├── cdc-reader/
│       ├── inventory-sync/
│       ├── orchestrator/
│       ├── postgres-source/
│       ├── postgres-target/
│       ├── redpanda/
│       ├── minio/
│       ├── grafana/
│       └── prometheus/
├── services/
│   ├── cdc-reader/                 # Go microservice — WAL reader
│   │   ├── main.go
│   │   ├── Dockerfile
│   │   ├── go.mod
│   │   ├── go.sum
│   │   └── internal/
│   │       ├── wal/                # pglogrepl WAL decoding logic
│   │       ├── schema/             # Schema Registry client
│   │       ├── producer/           # Redpanda Avro producer
│   │       └── health/             # /healthz /readyz /metrics handlers
│   ├── inventory-sync/             # Go microservice — Redpanda consumer
│   │   ├── main.go
│   │   ├── Dockerfile
│   │   ├── go.mod
│   │   ├── go.sum
│   │   └── internal/
│   │       ├── consumer/           # Redpanda consumer group logic
│   │       ├── dq/                 # Data quality checks
│   │       ├── postgres/           # Target DB upsert logic
│   │       ├── iceberg/            # Iceberg/MinIO Parquet writer
│   │       └── health/             # /healthz /readyz /metrics handlers
│   └── orchestrator/               # Go microservice — health monitor
│       ├── main.go
│       ├── Dockerfile
│       ├── go.mod
│       ├── go.sum
│       └── internal/
│           ├── probe/              # Polls /healthz on sibling services
│           ├── k8s/                # Kubernetes API client for pod restart
│           ├── alert/              # Prometheus alert trigger logic
│           └── health/             # /healthz /readyz /metrics handlers
├── scripts/
│   ├── setup/
│   │   ├── 01_init_postgres_source.sh   # Create source DB, enable WAL, create replication slot
│   │   ├── 02_load_olist_dataset.sh     # Download and load Olist CSVs into source DB
│   │   ├── 03_init_postgres_target.sh   # Create target DB, create serving schemas and indexes
│   │   ├── 04_create_redpanda_topics.sh # Create all cdc.* topics and cdc.dlq
│   │   ├── 05_bootstrap_minio.sh        # Create MinIO bucket and Iceberg namespace
│   │   └── 06_verify_setup.sh           # Smoke test — confirm all services are reachable
│   ├── cron/
│   │   ├── schema_drift_check.sh        # Compare source vs target schemas, log differences
│   │   └── iceberg_partition_cleanup.sh # Remove Iceberg partitions older than retention window
│   └── eda/
│       └── olist_eda.ipynb              # Python EDA notebook (pandas, matplotlib, seaborn)
├── sql/
│   ├── source/
│   │   └── schema.sql              # source_db DDL — all 7 raw tables with CDC columns
│   ├── staging/
│   │   └── schema.sql              # staging_db DDL — all 5 staging tables
│   └── serving/
│       └── schema.sql              # serving_db DDL — dim/fact tables + metrics_sync_latency
├── grafana/
│   ├── datasources/
│   │   ├── postgres.yaml           # PostgreSQL target datasource config
│   │   └── prometheus.yaml         # Prometheus datasource config
│   └── dashboards/
│       ├── pipeline-health.json    # Sync latency, throughput, DLQ, consumer lag
│       ├── inventory.json          # Stock by category, top sellers, low stock alerts
│       ├── orders.json             # Order funnel, fulfilment rate, revenue by state
│       └── customer-satisfaction.json  # Review scores, late delivery rate
├── prometheus/
│   └── prometheus.yml              # Scrape configs for all /metrics endpoints
└── docs/
    ├── architecture-diagram.png
    ├── table-schema.xlsx           # Q5 — 4 zones, 21 tables
    └── sttm.xlsx                   # Q6 — 31 source-to-target mappings
```

---

## Database Zones

### Zone 1 — source_db (PostgreSQL, port 5432)
Raw Olist data. WAL logical replication enabled. CDC origin point.
Tables: `orders`, `order_items`, `products`, `sellers`, `customers`, `order_payments`, `order_reviews`
Every table has two CDC metadata columns appended: `cdc_updated_at TIMESTAMP` and `cdc_operation VARCHAR(10)`.

### Zone 2 — staging_db (PostgreSQL, port 5432, separate schema)
Quality-checked data. Nulls filled, duplicates removed, outliers flagged, inventory derived.
Tables: `stg_orders`, `stg_order_items`, `stg_inventory`, `stg_products`, `stg_order_reviews`

### Zone 3 — serving_db (PostgreSQL, port 5433)
Analytics-ready. Indexed for Grafana queries. This is what all dashboards read.
Tables: `dim_products`, `dim_sellers`, `dim_customers`, `fact_orders`, `fact_inventory`, `metrics_sync_latency`

### Zone 4 — Lakehouse (MinIO + Apache Iceberg)
Parquet files partitioned by `_partition_date` (derived from `cdc_updated_at`).
Iceberg tables: `iceberg_orders`, `iceberg_inventory`, `iceberg_sync_metrics`

---

## Microservice Specifications

### CDC Reader (`services/cdc-reader/`)
**Language**: Go
**Port**: 8081
**Key dependencies**: `github.com/jackc/pglogrepl`, `github.com/twmb/franz-go`, `github.com/hamba/avro`

**Behaviour**:
1. On startup, connect to PostgreSQL replication slot (`cdc_slot`) using `pglogrepl`
2. If `INITIAL_SNAPSHOT=true` env var is set, perform a full table scan of all source tables and publish each row as an INSERT event before switching to streaming
3. Decode WAL messages into CDC events (table name, operation, before/after columns)
4. For each event, fetch or register the Avro schema with the Schema Registry
5. If schema change is detected:
   - **Backward compatible** (new nullable column added): auto-promote schema version, continue
   - **Breaking change** (column removed, type changed): publish event to `cdc.dlq` topic, log warning, do NOT crash
6. Serialize event as Avro and publish to `cdc.{table_name}` topic
7. On publish failure, retry with exponential backoff (max 5 attempts), then route to DLQ
8. Commit WAL LSN only after successful publish

**Probe endpoints**:
- `GET /healthz` — returns 200 if process is alive
- `GET /readyz` — returns 200 only if replication slot is active AND Redpanda connection is healthy
- `GET /metrics` — Prometheus metrics: `cdc_events_total`, `cdc_publish_errors_total`, `cdc_wal_lag_bytes`, `cdc_schema_version`

**Environment variables**:
```
POSTGRES_DSN=postgres://user:pass@postgres-source:5432/source_db
REPLICATION_SLOT=cdc_slot
REDPANDA_BROKERS=redpanda:9092
SCHEMA_REGISTRY_URL=http://redpanda:8084
INITIAL_SNAPSHOT=false
LOG_LEVEL=info
```

---

### Inventory Sync (`services/inventory-sync/`)
**Language**: Go
**Port**: 8082
**Key dependencies**: `github.com/twmb/franz-go`, `github.com/hamba/avro`, `github.com/jackc/pgx/v5`

**Behaviour**:
1. Subscribe to all `cdc.*` topics as consumer group `inventory-sync-group`
2. For each consumed message:
   a. Deserialize Avro using Schema Registry
   b. Run data quality checks (see DQ Rules below)
   c. If DQ check fails, route to `cdc.dlq` with failure reason metadata
   d. Upsert into PostgreSQL target using `ON CONFLICT DO UPDATE` — fully idempotent
   e. Write same record to MinIO via Iceberg writer as Parquet
   f. Commit Kafka offset **only after both writes succeed**
3. Record sync latency: `serving_write_timestamp - cdc_event_timestamp` → insert into `metrics_sync_latency`

**Data Quality Rules**:
- `review_score` NULL → fill with median score per `product_category_name`
- `order_delivered_customer_date` NULL → impute using avg shipping duration per seller state
- `price` > IQR upper bound → cap at upper bound, set `price_outlier_flag = true`
- Duplicate on `(order_id, product_id, seller_id)` → set `is_duplicate = true`, skip upsert
- `product_category_name` → join with translation table, populate `product_category_name_english`

**Probe endpoints**:
- `GET /healthz` — returns 200 if process is alive
- `GET /readyz` — returns 200 only if Redpanda consumer group is active AND PostgreSQL target is writable
- `GET /metrics` — Prometheus metrics: `sync_events_processed_total`, `sync_upsert_errors_total`, `sync_dq_failures_total`, `sync_latency_ms` (histogram), `sync_consumer_lag`

**Environment variables**:
```
REDPANDA_BROKERS=redpanda:9092
SCHEMA_REGISTRY_URL=http://redpanda:8084
CONSUMER_GROUP=inventory-sync-group
POSTGRES_TARGET_DSN=postgres://user:pass@postgres-target:5433/serving_db
MINIO_ENDPOINT=minio:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_BUCKET=lakehouse
ICEBERG_NAMESPACE=inventory
LOG_LEVEL=info
```

---

### Orchestrator (`services/orchestrator/`)
**Language**: Go
**Port**: 8083
**Key dependencies**: `k8s.io/client-go`, `github.com/prometheus/client_golang`

**Behaviour**:
1. Every 10 seconds, poll `GET /healthz` on CDC Reader (8081) and Inventory Sync (8082)
2. Track consecutive failure count per service
3. If a service fails 3 consecutive health checks:
   - Call Kubernetes API to delete the pod (K8s restarts it automatically via Deployment)
   - Log the restart event with timestamp and reason
   - Reset failure counter
4. Poll Prometheus for `sync_consumer_lag` metric every 30 seconds
   - If lag > 2000ms, trigger alert (log + webhook if `ALERT_WEBHOOK_URL` is set)
5. Poll Redpanda Admin API for `cdc.dlq` topic message count every 60 seconds
   - If DLQ depth > 100 unprocessed messages, trigger alert
6. Run schema drift check on demand via `POST /drift-check` endpoint

**Probe endpoints**:
- `GET /healthz` — returns 200 if process is alive
- `GET /readyz` — returns 200 if Kubernetes API and all sibling /healthz endpoints are reachable
- `GET /metrics` — Prometheus metrics: `orchestrator_restarts_total`, `orchestrator_dlq_depth`, `orchestrator_lag_alerts_total`
- `POST /drift-check` — triggers immediate schema comparison between source and target

**Environment variables**:
```
CDC_READER_URL=http://cdc-reader:8081
INVENTORY_SYNC_URL=http://inventory-sync:8082
PROMETHEUS_URL=http://prometheus:9090
REDPANDA_ADMIN_URL=http://redpanda:9644
KUBECONFIG=/var/run/secrets/kubernetes.io/serviceaccount
K8S_NAMESPACE=cdc-pipeline
ALERT_WEBHOOK_URL=
HEALTH_POLL_INTERVAL=10s
LAG_POLL_INTERVAL=30s
DLQ_POLL_INTERVAL=60s
LOG_LEVEL=info
```

---

## Redpanda Topics

| Topic | Partitions | Retention | Purpose |
|---|---|---|---|
| `cdc.orders` | 3 | 24h | Order CDC events |
| `cdc.order_items` | 3 | 24h | Order item CDC events |
| `cdc.products` | 3 | 24h | Product CDC events |
| `cdc.sellers` | 1 | 24h | Seller CDC events |
| `cdc.customers` | 3 | 24h | Customer CDC events |
| `cdc.order_payments` | 3 | 24h | Payment CDC events |
| `cdc.order_reviews` | 1 | 24h | Review CDC events |
| `cdc.dlq` | 1 | 7d | Dead-letter — breaking changes, DQ failures |

---

## Setup Scripts — Rules

All scripts in `scripts/setup/` must follow these rules:
1. **Idempotent** — running a script twice must produce the same result. Use `IF NOT EXISTS`, `CREATE OR REPLACE`, `--on-conflict` patterns throughout.
2. **Numbered** — scripts are executed in order: `01_` → `02_` → ... → `06_`
3. **Exit on error** — every script must start with `set -euo pipefail`
4. **Verification** — every script must print a success message and a summary of what was created
5. **No hardcoded credentials** — read from environment variables or `.env` file

**Execution order**:
```bash
# Run all setup scripts in order
bash scripts/setup/01_init_postgres_source.sh
bash scripts/setup/02_load_olist_dataset.sh
bash scripts/setup/03_init_postgres_target.sh
bash scripts/setup/04_create_redpanda_topics.sh
bash scripts/setup/05_bootstrap_minio.sh
bash scripts/setup/06_verify_setup.sh
```

---

## Kubernetes & Helm Rules

### Every microservice Kubernetes Deployment must include:
```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: <service_port>
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /readyz
    port: <service_port>
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 3
```

### Helm chart structure rules:
- Non-sensitive config → `ConfigMap` referenced via `envFrom`
- Sensitive config (DSNs, passwords, keys) → `Secret` referenced via `envFrom`
- All services get a `ClusterIP` Service exposing their port
- Grafana and Prometheus get `NodePort` Services for local browser access
- `values.yaml` uses local endpoints (e.g. `minio:9000`)
- `values-cloud.yaml` overrides to cloud endpoints (e.g. `s3.amazonaws.com`)

### Kubernetes CronJobs:
```yaml
# Schema drift check — runs daily at midnight
schedule: "0 0 * * *"
script: scripts/cron/schema_drift_check.sh

# Iceberg partition cleanup — runs weekly on Sunday
schedule: "0 2 * * 0"
script: scripts/cron/iceberg_partition_cleanup.sh
```

---

## Go Coding Standards

1. **Module names**: `github.com/your-org/cdc-reader`, `github.com/your-org/inventory-sync`, `github.com/your-org/orchestrator`
2. **Logging**: Use `zerolog` with structured JSON output. Every log entry must include `service`, `level`, `timestamp`, and relevant context fields.
3. **Error handling**: Never use `panic()` in production code paths. Return errors up the call stack and log at the point of handling.
4. **Retry logic**: Use exponential backoff with jitter for all external calls (Redpanda publish, PostgreSQL write, MinIO write). Max 5 retries.
5. **Graceful shutdown**: All services must handle `SIGTERM` and `SIGINT`, drain in-flight work, and exit cleanly within 30 seconds.
6. **Config**: All configuration via environment variables. No hardcoded values anywhere.
7. **Dockerfile**: Multi-stage build. Builder stage uses `golang:1.22-alpine`. Final stage uses `alpine:3.19`. No unnecessary binaries in final image.
8. **Tests**: Unit tests for all DQ logic, schema evolution detection, and upsert idempotency. Use `testing` standard library. Place tests in `*_test.go` files alongside source.

**Standard main.go structure for every service**:
```go
func main() {
    // 1. Load config from env
    // 2. Init logger (zerolog)
    // 3. Init dependencies (DB connections, Redpanda client, etc.)
    // 4. Start /healthz /readyz /metrics HTTP server in goroutine
    // 5. Start main service loop in goroutine
    // 6. Block on os.Signal (SIGTERM / SIGINT)
    // 7. Trigger graceful shutdown with 30s timeout context
}
```

---

## Grafana Dashboards

Four dashboards must be provisioned automatically via `grafana/dashboards/*.json`. They must load on first Grafana startup without manual import.

### Dashboard 1 — Pipeline Health
Data source: Prometheus
Panels:
- Sync latency histogram (P50, P95, P99) — from `metrics_sync_latency` table
- CDC events per second — from `cdc_events_total` counter
- Dead-letter queue depth — from `orchestrator_dlq_depth` gauge
- Consumer lag per topic — from `sync_consumer_lag` gauge
- Pod restart count — from `orchestrator_restarts_total` counter

### Dashboard 2 — Inventory
Data source: PostgreSQL target
Panels:
- Total units sold by product category (bar chart)
- Top 10 sellers by revenue (table)
- Low stock alert — products with < threshold units sold in last 7 days
- Units sold over time (time series)

### Dashboard 3 — Orders
Data source: PostgreSQL target
Panels:
- Order status funnel (created → approved → shipped → delivered)
- Order fulfilment rate — on-time vs late (pie chart)
- Revenue by customer state (bar chart)
- Orders over time (time series)

### Dashboard 4 — Customer Satisfaction
Data source: PostgreSQL target
Panels:
- Average review score by product category
- Late delivery rate by seller (table, sortable)
- Review score distribution (histogram)
- Fulfilment score trend over time

---

## Development Phases Reference

| Phase | Scope | Delivery |
|---|---|---|
| **Phase 1** | Architecture design, Q1–Q6 answers, table schema, STTM | May 1, 2026 |
| **Phase 2** | Infrastructure setup, PostgreSQL + Redpanda + MinIO, CDC Reader Go service | May 6, 2026 |
| **Phase 3** | Inventory Sync service, Kafka integration, Grafana dashboards | May 9, 2026 |
| **Phase 4** | Orchestrator service, full documentation, final PPT | May 11, 2026 |

---

## Phase 2 — Implementation Checklist

When implementing Phase 2, complete the following in order:

- [ ] Write `docker-compose.yml` with all services (PostgreSQL x2, Redpanda, MinIO, Grafana, Prometheus)
- [ ] Write `scripts/setup/01_init_postgres_source.sh` — enable WAL, create replication slot, create source_db schema
- [ ] Write `scripts/setup/02_load_olist_dataset.sh` — download Kaggle CSVs, COPY into source tables
- [ ] Write `scripts/setup/03_init_postgres_target.sh` — create serving_db schema, add indexes
- [ ] Write `scripts/setup/04_create_redpanda_topics.sh` — create all 8 topics
- [ ] Write `scripts/setup/05_bootstrap_minio.sh` — create bucket and Iceberg namespace
- [ ] Write `scripts/setup/06_verify_setup.sh` — smoke test all services
- [ ] Write `sql/source/schema.sql` — all 7 source tables with CDC columns
- [ ] Write `sql/serving/schema.sql` — all 6 serving tables with indexes
- [ ] Implement `services/cdc-reader/` Go service — WAL reading, Avro encoding, schema registration, dead-letter routing
- [ ] Write `services/cdc-reader/Dockerfile` — multi-stage build
- [ ] Write Helm templates for PostgreSQL source, Redpanda, MinIO, and CDC Reader
- [ ] Write `helm/values.yaml` with all local defaults

## Phase 3 — Implementation Checklist

- [ ] Implement `services/inventory-sync/` Go service — consumer, DQ checks, PostgreSQL upsert, Iceberg writer
- [ ] Write `services/inventory-sync/Dockerfile`
- [ ] Write Helm templates for Inventory Sync, PostgreSQL target, Grafana, Prometheus
- [ ] Write `grafana/dashboards/pipeline-health.json`
- [ ] Write `grafana/dashboards/inventory.json`
- [ ] Write `grafana/dashboards/orders.json`
- [ ] Write `grafana/dashboards/customer-satisfaction.json`
- [ ] Write `prometheus/prometheus.yml` with all scrape targets

## Phase 4 — Implementation Checklist

- [ ] Implement `services/orchestrator/` Go service — health polling, K8s restart, DLQ monitoring, drift check
- [ ] Write `services/orchestrator/Dockerfile`
- [ ] Write Helm template for Orchestrator with K8s RBAC (ServiceAccount + Role + RoleBinding)
- [ ] Write `scripts/cron/schema_drift_check.sh`
- [ ] Write `scripts/cron/iceberg_partition_cleanup.sh`
- [ ] Write `helm/values-cloud.yaml` with cloud endpoint overrides
- [ ] Verify full stack runs end-to-end with `helm install` on kind cluster

---

## Local Development — Quick Start

```bash
# 1. Start all infrastructure services
docker-compose up -d

# 2. Run setup scripts in order
for script in scripts/setup/*.sh; do bash "$script"; done

# 3. Build and start microservices (development mode)
cd services/cdc-reader && go run ./main.go &
cd services/inventory-sync && go run ./main.go &
cd services/orchestrator && go run ./main.go &

# 4. Open dashboards
# Grafana:    http://localhost:3000  (admin / admin)
# MinIO:      http://localhost:9001  (minioadmin / minioadmin)
# Prometheus: http://localhost:9090
```

---

## Key Design Decisions — Do Not Change Without Discussion

1. **Schema evolution strategy**: backward-compatible changes are auto-promoted. Breaking changes always go to DLQ — they never crash the pipeline.
2. **Idempotency**: PostgreSQL upserts use `ON CONFLICT DO UPDATE`. Iceberg uses MERGE. Processing the same event twice must produce the same result.
3. **Offset commitment**: Inventory Sync commits Kafka offset only after BOTH the PostgreSQL upsert AND the Iceberg write succeed. If either fails, the event is reprocessed.
4. **WAL LSN commitment**: CDC Reader commits the WAL LSN only after Redpanda publish succeeds. If Redpanda is down, WAL position is held — no events are lost.
5. **Probe semantics**: `/healthz` means the process is alive. `/readyz` means the service is ready to process traffic (all upstream connections verified). Kubernetes uses both independently.
6. **No direct Iceberg queries in Grafana**: Grafana reads from PostgreSQL target only for real-time panels. Iceberg is queried via DuckDB/Trino for historical panels only, keeping the live pipeline unaffected.
7. **Local-first**: All defaults in `values.yaml` point to local services. Cloud migration is a `values-cloud.yaml` override — zero code changes required.
