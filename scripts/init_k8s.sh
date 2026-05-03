#!/usr/bin/env bash
# init_k8s.sh — create a local kind cluster and deploy the CDC Helm chart.
# Safe to re-run: cluster creation and helm install are both idempotent.
set -euo pipefail

CLUSTER_NAME="cdc"
NAMESPACE="cdc-pipeline"
CHART_DIR="$(cd "$(dirname "$0")/../helm" && pwd)"
KIND_CONFIG="$(cd "$(dirname "$0")/.." && pwd)/kind-config.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[init_k8s]${RESET} $*"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
die()     { echo -e "${RED}[ FAIL ]${RESET} $*" >&2; exit 1; }

# ─── pre-flight checks ────────────────────────────────────────────────────────
for bin in kind kubectl helm docker; do
  command -v "$bin" &>/dev/null || die "'$bin' not found — run scripts/init_env.sh first."
done

docker info &>/dev/null || die "Docker daemon is not running."

# Warn if docker compose is still up (port conflicts)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE 'postgres-source|postgres-target|redpanda|minio|grafana|prometheus'; then
  warn "docker compose containers appear to be running."
  warn "They share ports with the kind NodePort mappings."
  warn "Run 'docker compose down' first to avoid conflicts."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || exit 1
fi

# ─── 1. Create kind cluster ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ 1/3  kind cluster ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  success "Cluster '${CLUSTER_NAME}' already exists."
else
  log "Creating kind cluster '${CLUSTER_NAME}' …"
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  success "Cluster '${CLUSTER_NAME}' created."
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null \
  || die "Cannot reach cluster context 'kind-${CLUSTER_NAME}'."

# ─── 2. Set kubectl context ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ 2/3  kubectl context ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

kubectl config use-context "kind-${CLUSTER_NAME}"
success "Active context: kind-${CLUSTER_NAME}"

# ─── 3. Helm install / upgrade ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ 3/3  Helm deploy ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

log "Running helm upgrade --install cdc-pipeline …"
helm upgrade --install cdc-pipeline "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${CHART_DIR}/values.yaml" \
  --wait \
  --timeout 5m

success "Helm release 'cdc-pipeline' deployed."

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Cluster ready ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
kubectl get pods -n "${NAMESPACE}"
echo ""
echo -e "${BOLD}Access URLs (via kind port mappings):${RESET}"
echo "  Grafana:          http://localhost:3000  (admin / admin)"
echo "  Prometheus:       http://localhost:9090"
echo "  MinIO console:    http://localhost:9001  (minioadmin / minioadmin)"
echo "  MinIO API:        http://localhost:9000"
echo "  Redpanda Kafka:   localhost:9092"
echo "  Schema Registry:  http://localhost:8084"
echo "  Redpanda Admin:   http://localhost:9644"
echo "  PG source (host): localhost:5434"
echo "  PG target (host): localhost:5433"
echo ""
echo -e "${BOLD}To deploy Go services once images are built:${RESET}"
echo "  kind load docker-image cdc-reader:latest --name ${CLUSTER_NAME}"
echo "  kind load docker-image inventory-sync:latest --name ${CLUSTER_NAME}"
echo "  kind load docker-image orchestrator:latest --name ${CLUSTER_NAME}"
echo "  helm upgrade cdc-pipeline helm/ --namespace ${NAMESPACE} \\"
echo "    --set cdcReader.enabled=true \\"
echo "    --set inventorySync.enabled=true \\"
echo "    --set orchestrator.enabled=true"
echo ""
success "Done."
