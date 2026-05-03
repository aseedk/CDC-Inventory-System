#!/usr/bin/env bash
# init_k8s.sh — create a local kind cluster, deploy the CDC Helm chart,
#               and install Kubernetes Dashboard v3.
# Safe to re-run: every step is idempotent.
set -euo pipefail

CLUSTER_NAME="cdc"
NAMESPACE="cdc-pipeline"
DASHBOARD_NAMESPACE="kubernetes-dashboard"
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
echo -e "${BOLD}━━━ 1/4  kind cluster ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

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
echo -e "${BOLD}━━━ 2/4  kubectl context ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

kubectl config use-context "kind-${CLUSTER_NAME}"
success "Active context: kind-${CLUSTER_NAME}"

# ─── 3. Helm deploy — CDC pipeline ───────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ 3/4  Helm deploy (CDC pipeline) ━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

log "Running helm upgrade --install cdc-pipeline …"
helm upgrade --install cdc-pipeline "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${CHART_DIR}/values.yaml" \
  --wait \
  --timeout 5m

success "Helm release 'cdc-pipeline' deployed."

# ─── 4. Kubernetes Dashboard v2 ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ 4/4  Kubernetes Dashboard ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

DASHBOARD_MANIFEST="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"

if kubectl get deployment kubernetes-dashboard -n "${DASHBOARD_NAMESPACE}" &>/dev/null; then
  log "Kubernetes Dashboard already installed — skipping."
else
  log "Installing Kubernetes Dashboard v2.7.0 …"
  kubectl apply -f "${DASHBOARD_MANIFEST}"
  log "Waiting for dashboard pod to be ready …"
  kubectl rollout status deployment/kubernetes-dashboard \
    -n "${DASHBOARD_NAMESPACE}" --timeout=120s
fi

success "Kubernetes Dashboard installed."

# Create admin ServiceAccount + ClusterRoleBinding (idempotent via apply)
log "Configuring admin-user ServiceAccount …"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: ${DASHBOARD_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: ${DASHBOARD_NAMESPACE}
EOF

success "admin-user ServiceAccount ready."

# Generate a 24-hour access token and save it to a file
TOKEN=$(kubectl -n "${DASHBOARD_NAMESPACE}" create token admin-user --duration=24h)
TOKEN_FILE="$(cd "$(dirname "$0")/.." && pwd)/.dashboard-token"
echo "${TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"
log "Access token saved to .dashboard-token (valid 24 h)"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Cluster ready ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
kubectl get pods -n "${NAMESPACE}"
echo ""
echo -e "${BOLD}CDC pipeline access (via kind NodePort mappings):${RESET}"
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
echo -e "${BOLD}Kubernetes Dashboard:${RESET}"
echo "  Start:   bash scripts/k8s-ui.sh"
echo "  URL:     https://localhost:8443"
echo "  Token:   cat .dashboard-token"
echo "  Refresh: bash scripts/k8s-ui.sh token"
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
