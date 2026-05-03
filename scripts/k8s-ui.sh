#!/usr/bin/env bash
# k8s-ui.sh — start / stop the Kubernetes Dashboard port-forward.
#
# Usage:
#   bash scripts/k8s-ui.sh          # start (prints URL + token)
#   bash scripts/k8s-ui.sh stop     # kill the port-forward
#   bash scripts/k8s-ui.sh token    # print a fresh 24-hour token
set -euo pipefail

DASHBOARD_NAMESPACE="kubernetes-dashboard"
DASHBOARD_SVC="kubernetes-dashboard"
LOCAL_PORT=8443
PID_FILE="/tmp/k8s-dashboard-pf.pid"
TOKEN_FILE="$(cd "$(dirname "$0")/.." && pwd)/.dashboard-token"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[k8s-ui]${RESET} $*"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }

# ─── stop ────────────────────────────────────────────────────────────────────
cmd_stop() {
  if [[ -f "${PID_FILE}" ]]; then
    PID=$(cat "${PID_FILE}")
    if kill -0 "${PID}" 2>/dev/null; then
      kill "${PID}"
      success "Port-forward (PID ${PID}) stopped."
    else
      warn "Port-forward process not running (stale PID file)."
    fi
    rm -f "${PID_FILE}"
  else
    warn "No port-forward PID file found — nothing to stop."
  fi
}

# ─── token ───────────────────────────────────────────────────────────────────
cmd_token() {
  TOKEN=$(kubectl -n "${DASHBOARD_NAMESPACE}" create token admin-user --duration=24h)
  echo "${TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  echo ""
  echo -e "${BOLD}Fresh token (valid 24 h):${RESET}"
  echo "${TOKEN}"
  echo ""
  success "Token also saved to .dashboard-token"
}

# ─── start (default) ─────────────────────────────────────────────────────────
cmd_start() {
  # Verify dashboard is installed
  kubectl get svc "${DASHBOARD_SVC}" -n "${DASHBOARD_NAMESPACE}" &>/dev/null \
    || { echo "Kubernetes Dashboard not found. Run scripts/init_k8s.sh first."; exit 1; }

  # Kill any existing port-forward on this port
  if [[ -f "${PID_FILE}" ]]; then
    OLD_PID=$(cat "${PID_FILE}")
    kill -0 "${OLD_PID}" 2>/dev/null && kill "${OLD_PID}" && log "Killed previous port-forward (PID ${OLD_PID})."
    rm -f "${PID_FILE}"
  fi

  # Start port-forward in background
  kubectl port-forward \
    -n "${DASHBOARD_NAMESPACE}" \
    "svc/${DASHBOARD_SVC}" \
    "${LOCAL_PORT}:443" \
    &>/tmp/k8s-dashboard-pf.log &
  PF_PID=$!
  echo "${PF_PID}" > "${PID_FILE}"

  # Wait briefly to confirm it bound successfully
  sleep 3
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    echo "Port-forward failed to start. Check /tmp/k8s-dashboard-pf.log"
    exit 1
  fi

  success "Port-forward running (PID ${PF_PID})."

  # Get or refresh the token
  if [[ ! -f "${TOKEN_FILE}" ]]; then
    cmd_token > /dev/null
  fi
  TOKEN=$(cat "${TOKEN_FILE}")

  echo ""
  echo -e "${BOLD}━━━ Kubernetes Dashboard ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "  URL:   ${BOLD}https://localhost:${LOCAL_PORT}${RESET}"
  echo ""
  echo -e "  ${YELLOW}Your browser will show a certificate warning — click 'Advanced'"
  echo -e "  then 'Proceed to localhost' (self-signed cert, safe for local use).${RESET}"
  echo ""
  echo -e "  Token:"
  echo ""
  echo "  ${TOKEN}"
  echo ""
  echo -e "  Paste the token into the Dashboard login page and click 'Sign in'."
  echo ""
  echo -e "  To stop:         bash scripts/k8s-ui.sh stop"
  echo -e "  To refresh token: bash scripts/k8s-ui.sh token"
  echo ""
}

# ─── dispatch ────────────────────────────────────────────────────────────────
case "${1:-start}" in
  start) cmd_start ;;
  stop)  cmd_stop  ;;
  token) cmd_token ;;
  *) echo "Usage: $0 [start|stop|token]"; exit 1 ;;
esac
