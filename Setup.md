# CDC Inventory Sync System — Setup Guide

This guide walks through the complete setup from a fresh Windows machine to a fully running CDC pipeline, first verified via Docker Compose and then deployed on local Kubernetes.

---

## Table of Contents

1. [WSL2 Setup](#1-wsl2-setup)
2. [Environment Bootstrap](#2-environment-bootstrap)
3. [Stage 1 — Docker Compose (verify containerisation)](#3-stage-1--docker-compose)
4. [Stage 2 — Kubernetes via Helm](#4-stage-2--kubernetes-via-helm)
5. [Kubernetes Dashboard UI](#5-kubernetes-dashboard-ui)
6. [Port Reference](#6-port-reference)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. WSL2 Setup

### 1.1 Enable WSL2 on Windows

Open **PowerShell as Administrator** and run:

```powershell
wsl --install
```

This installs WSL2 and Ubuntu by default. Reboot when prompted.

If WSL is already installed but on version 1, upgrade it:

```powershell
wsl --set-default-version 2
```

### 1.2 Install Debian (recommended for this project)

```powershell
wsl --install -d Debian
```

Launch Debian from the Start menu and complete the initial user setup (username + password).

### 1.3 Enable systemd (optional but recommended)

Systemd allows Docker to start automatically on WSL boot. Inside your Debian terminal:

```bash
sudo nano /etc/wsl.conf
```

Add:

```ini
[boot]
systemd=true
```

Save, then restart WSL from PowerShell:

```powershell
wsl --shutdown
```

Re-open Debian. Verify systemd is running:

```bash
systemctl is-system-running
```

> **Without systemd:** Docker must be started manually each session with `sudo dockerd &` — the `init_env.sh` script handles this fallback automatically.

### 1.4 Navigate to the project

```bash
cd ~/workspace/"CDC Inventory Sync System"
```

---

## 2. Environment Bootstrap

This installs all host-level tools: Docker, Docker Compose, kubectl, kind, Helm, and Go.

```bash
bash scripts/init_env.sh
```

The script is **idempotent** — safe to re-run. It will skip any tool already at the correct version.

After it completes, reload your shell so the new PATH entries (Go, etc.) take effect:

```bash
source ~/.bashrc
```

Verify the key tools are available:

```bash
docker --version
docker compose version
kubectl version --client
kind version
helm version --short
go version
```

---

## 3. Stage 1 — Docker Compose

Use Docker Compose to verify all containers start, are healthy, and are accessible before moving to Kubernetes.

### 3.1 Configure credentials

```bash
cp .env.example .env
```

The defaults in `.env.example` are fine for local development. Edit `.env` if you want custom passwords.

### 3.2 Start the infrastructure stack

```bash
docker compose up -d
```

This pulls and starts six containers: `postgres-source`, `postgres-target`, `redpanda`, `minio`, `prometheus`, `grafana`.

### 3.3 Verify all containers are healthy

```bash
docker ps
```

All six containers should show `(healthy)` in the STATUS column within ~60 seconds. If any show `(unhealthy)` check its logs:

```bash
docker logs <container-name>
```

### 3.4 Access the services

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin |
| MinIO API | http://localhost:9000 | — |
| Redpanda Admin | http://localhost:9644 | — |
| Schema Registry | http://localhost:8084 | — |
| PostgreSQL source | localhost:5434 | postgres / postgres |
| PostgreSQL target | localhost:5433 | postgres / postgres |

### 3.5 Tear down when done

Once you have confirmed everything is working, bring the stack down before proceeding to Kubernetes (they share the same host ports):

```bash
docker compose down
```

---

## 4. Stage 2 — Kubernetes via Helm

### 4.1 Run the Kubernetes setup script

This single script:
- Creates a local **kind** cluster using `kind-config.yaml`
- Sets the correct `kubectl` context
- Deploys all services via the Helm chart in `helm/`
- Installs **Kubernetes Dashboard v2.7** and creates an admin access token

```bash
bash scripts/init_k8s.sh
```

> The script is idempotent. If the kind cluster already exists it will skip creation and go straight to Helm upgrade.

The first run takes 3–6 minutes (image pulls). You will see four steps:

```
━━━ 1/4  kind cluster
━━━ 2/4  kubectl context
━━━ 3/4  Helm deploy (CDC pipeline)
━━━ 4/4  Kubernetes Dashboard
```

### 4.2 Verify all pods are running

```bash
kubectl get pods -n cdc-pipeline
```

Expected output — all pods `1/1 Running`:

```
NAME                         READY   STATUS    RESTARTS   AGE
grafana-xxxx                 1/1     Running   0          2m
minio-0                      1/1     Running   0          2m
postgres-source-0            1/1     Running   0          2m
postgres-target-0            1/1     Running   0          2m
prometheus-xxxx              1/1     Running   0          2m
redpanda-0                   1/1     Running   0          2m
```

### 4.3 Access the services

Services are exposed via **NodePort** and mapped to host ports in `kind-config.yaml`. The URLs are identical to Docker Compose:

| Service | URL | Credentials |
|---|---|---|
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin |
| MinIO API | http://localhost:9000 | — |
| Redpanda Admin | http://localhost:9644 | — |
| Schema Registry | http://localhost:8084 | — |
| PostgreSQL source | localhost:5434 | postgres / postgres |
| PostgreSQL target | localhost:5433 | postgres / postgres |

### 4.4 Inspect the Helm release

```bash
# List deployed releases
helm list -n cdc-pipeline

# Show rendered manifests
helm get manifest cdc-pipeline -n cdc-pipeline

# Upgrade with a values override
helm upgrade cdc-pipeline helm/ -n cdc-pipeline --set grafana.credentials.adminPassword=newpass
```

### 4.5 Enabling Go microservices (Phase 2+)

Once the Go services are built and their Docker images exist, load them into kind and enable them:

```bash
# Load locally built images into the kind cluster
kind load docker-image cdc-reader:latest     --name cdc
kind load docker-image inventory-sync:latest --name cdc
kind load docker-image orchestrator:latest   --name cdc

# Upgrade the Helm release to enable all three services
helm upgrade cdc-pipeline helm/ \
  --namespace cdc-pipeline \
  --set cdcReader.enabled=true \
  --set inventorySync.enabled=true \
  --set orchestrator.enabled=true
```

---

## 5. Kubernetes Dashboard UI

The Kubernetes Dashboard gives you a visual view of all cluster resources: pods, deployments, services, logs, and more.

### 5.1 Start the Dashboard

```bash
bash scripts/k8s-ui.sh
```

The script starts a `kubectl port-forward` in the background and prints the access URL and login token:

```
━━━ Kubernetes Dashboard ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  URL:   https://localhost:8443

  Token:
  eyJhbGciOiJSUzI1NiIsImtpZCI6...  (long token string)

  Paste the token into the Dashboard login page and click 'Sign in'.
```

### 5.2 Log in to the Dashboard

1. Open **https://localhost:8443** in your browser
2. Your browser will show a **certificate warning** — this is expected (self-signed cert)
   - Chrome/Edge: click **Advanced** → **Proceed to localhost (unsafe)**
   - Firefox: click **Advanced** → **Accept the Risk and Continue**
3. On the login page, select **Token**
4. Paste the token printed by `k8s-ui.sh` (or run `cat .dashboard-token`)
5. Click **Sign in**

### 5.3 Navigate the Dashboard

Once logged in, use the namespace selector in the top navigation to switch between namespaces:

- **cdc-pipeline** — all CDC infrastructure pods, services, PVCs
- **kubernetes-dashboard** — the dashboard itself
- **default** — cluster-level resources

Key sections:
- **Workloads → Pods** — view pod status and live logs
- **Workloads → StatefulSets** — postgres, redpanda, minio
- **Workloads → Deployments** — grafana, prometheus (and Go services when enabled)
- **Config and Storage → Persistent Volume Claims** — storage for each stateful service
- **Discovery and Load Balancing → Services** — all ClusterIP and NodePort services

### 5.4 View pod logs in the Dashboard

1. Go to **Workloads → Pods**
2. Select the `cdc-pipeline` namespace
3. Click any pod name
4. Click the **logs icon** (top right of the pod detail page)

### 5.5 Refresh the access token

Tokens are valid for **24 hours**. To generate a fresh token:

```bash
bash scripts/k8s-ui.sh token
```

The new token is printed to the terminal and saved to `.dashboard-token`.

### 5.6 Stop the Dashboard port-forward

```bash
bash scripts/k8s-ui.sh stop
```

---

## 6. Port Reference

| Port | Protocol | Service | Notes |
|---|---|---|---|
| 3000 | HTTP | Grafana | Dashboards |
| 5433 | TCP | PostgreSQL target | serving\_db |
| 5434 | TCP | PostgreSQL source | source\_db (WAL enabled) |
| 8084 | HTTP | Redpanda Schema Registry | Avro schema management |
| 8443 | HTTPS | Kubernetes Dashboard | Via port-forward only |
| 9000 | HTTP | MinIO S3 API | Object storage |
| 9001 | HTTP | MinIO Console | Web UI |
| 9090 | HTTP | Prometheus | Metrics |
| 9092 | TCP | Redpanda Kafka | Kafka broker |
| 9644 | HTTP | Redpanda Admin API | Cluster management |

---

## 7. Troubleshooting

### Docker daemon not running (WSL2 without systemd)

```bash
sudo dockerd &
# wait ~5 seconds, then retry
docker info
```

### Port already in use on `docker compose up`

Another process (or a previous container) is using one of the mapped ports. Find and stop it:

```bash
sudo lsof -i :<port>
sudo kill <PID>
```

### Helm release stuck in `pending-install`

A previous failed install left Helm in a bad state. Reset it:

```bash
helm uninstall cdc-pipeline -n cdc-pipeline
# then re-run:
bash scripts/init_k8s.sh
```

If the namespace is missing:

```bash
kubectl delete secret -n cdc-pipeline -l owner=helm,name=cdc-pipeline --ignore-not-found
bash scripts/init_k8s.sh
```

### Redpanda pod in CrashLoopBackOff

Force a fresh restart (the StatefulSet will recreate the pod with the current spec):

```bash
kubectl delete pod -n cdc-pipeline redpanda-0
kubectl logs -n cdc-pipeline redpanda-0 --follow
```

### Pod stuck in `Pending` state

Usually a PVC that cannot be provisioned. Check events:

```bash
kubectl describe pod -n cdc-pipeline <pod-name>
kubectl get pvc -n cdc-pipeline
```

### Dashboard certificate warning

This is normal for local development — the Dashboard uses a self-signed certificate. Click through the browser warning as described in [Section 5.2](#52-log-in-to-the-dashboard). Do not expose this dashboard outside your local machine.

### Token expired (dashboard login fails)

```bash
bash scripts/k8s-ui.sh token
# copy the new token and paste it into the login page
```

### Checking all resource health at once

```bash
kubectl get all -n cdc-pipeline
kubectl get pvc  -n cdc-pipeline
kubectl get events -n cdc-pipeline --sort-by='.lastTimestamp' | tail -20
```
