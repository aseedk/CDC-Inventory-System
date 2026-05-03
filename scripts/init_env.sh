#!/usr/bin/env bash
# init_env.sh — bootstrap the host machine for the CDC Inventory Sync pipeline.
# Installs: Docker Engine, Docker Compose v2, kubectl, kind, Helm, Go.
# Redpanda, PostgreSQL, and MinIO run as Docker containers — no host binaries needed.
# Safe to re-run — every step is idempotent.
set -euo pipefail

# ─── pinned versions ──────────────────────────────────────────────────────────
KUBECTL_VERSION="1.30.2"
KIND_VERSION="0.23.0"
HELM_VERSION="3.15.2"
GO_VERSION="1.25.9"

# ─── colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${CYAN}[init_env]${RESET} $*"; }
success() { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
die()     { echo -e "${RED}[ FAIL ]${RESET} $*" >&2; exit 1; }

step() {
  echo ""
  echo -e "${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ─── helper: is a binary already on PATH? ────────────────────────────────────
has() { command -v "$1" &>/dev/null; }

# ─── root / sudo guard ───────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
  warn "Not running as root — will use sudo for privileged steps."
else
  SUDO=""
fi

# ─── OS detection ────────────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
  die "Cannot detect OS — /etc/os-release missing."
fi
# shellcheck source=/dev/null
source /etc/os-release
DISTRO="${ID}"
CODENAME="${VERSION_CODENAME:-trixie}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

log "Detected OS : ${PRETTY_NAME:-$DISTRO}"
log "Codename    : ${CODENAME}"
log "Arch        : ${ARCH}"

case "$DISTRO" in
  debian|ubuntu) ;;
  *) die "Unsupported distro: $DISTRO. This script targets Debian/Ubuntu only." ;;
esac

# ─── 1. APT base dependencies ────────────────────────────────────────────────
step "1/8  Base packages"

$SUDO apt-get update -qq
$SUDO apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq \
  make \
  unzip

success "Base packages ready."

# ─── 2. Docker Engine ────────────────────────────────────────────────────────
step "2/8  Docker Engine"

if has docker && docker info &>/dev/null; then
  success "Docker already installed: $(docker --version)"
else
  log "Installing Docker Engine for ${DISTRO}/${CODENAME} …"

  $SUDO install -m 0755 -d /etc/apt/keyrings

  curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" \
    | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  success "Docker installed: $(docker --version)"
fi

# ─── 3. Docker daemon (WSL2-safe start) ──────────────────────────────────────
step "3/8  Docker daemon"

if docker info &>/dev/null; then
  success "Docker daemon already running."
else
  if systemctl is-active docker &>/dev/null 2>&1; then
    $SUDO systemctl enable --now docker
  else
    warn "systemd not available (WSL2?). Attempting to start dockerd directly."
    $SUDO dockerd >/tmp/dockerd.log 2>&1 &
    DOCKERD_PID=$!
    log "Waiting for dockerd to become ready (PID=${DOCKERD_PID}) …"
    for i in $(seq 1 15); do
      sleep 2
      if docker info &>/dev/null; then
        success "dockerd is ready."
        break
      fi
      if [[ $i -eq 15 ]]; then
        warn "dockerd did not become ready after 30s."
        warn "On WSL2 you can enable systemd in /etc/wsl.conf or run 'sudo dockerd &' manually."
        warn "See /tmp/dockerd.log for details."
      fi
    done
  fi
fi

# Add current user to docker group so non-root usage works after next login.
if [[ $EUID -ne 0 ]]; then
  if ! groups "$USER" | grep -qw docker; then
    $SUDO usermod -aG docker "$USER"
    warn "Added $USER to the docker group — re-login to apply."
  fi
fi

# ─── 4. Docker Compose v2 (plugin check) ─────────────────────────────────────
step "4/8  Docker Compose v2"

if docker compose version &>/dev/null; then
  success "Docker Compose ready: $(docker compose version)"
else
  log "Installing Docker Compose v2 standalone …"
  COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-${ARCH}"
  $SUDO mkdir -p /usr/local/lib/docker/cli-plugins
  $SUDO curl -fsSL "${COMPOSE_URL}" -o /usr/local/lib/docker/cli-plugins/docker-compose
  $SUDO chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  success "Docker Compose installed: $(docker compose version)"
fi

# ─── 5. kubectl ──────────────────────────────────────────────────────────────
step "5/8  kubectl ${KUBECTL_VERSION}"

if has kubectl && kubectl version --client 2>/dev/null | grep -qF "v${KUBECTL_VERSION}"; then
  success "kubectl already at v${KUBECTL_VERSION}."
else
  log "Installing kubectl v${KUBECTL_VERSION} …"
  curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /tmp/kubectl
  $SUDO install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
  success "kubectl installed: $(kubectl version --client 2>/dev/null | head -1)"
fi

# ─── 6. kind ─────────────────────────────────────────────────────────────────
step "6/8  kind ${KIND_VERSION}"

if has kind && kind version 2>/dev/null | grep -qF "v${KIND_VERSION}"; then
  success "kind already at v${KIND_VERSION}."
else
  log "Installing kind v${KIND_VERSION} …"
  curl -fsSL "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${ARCH}" -o /tmp/kind
  $SUDO install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
  success "kind installed: $(kind version)"
fi

# ─── 7. Helm ─────────────────────────────────────────────────────────────────
step "7/8  Helm ${HELM_VERSION}"

if has helm && helm version --short 2>/dev/null | grep -qF "v${HELM_VERSION}"; then
  success "Helm already at v${HELM_VERSION}."
else
  log "Installing Helm v${HELM_VERSION} …"
  HELM_TARBALL="helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSL "https://get.helm.sh/${HELM_TARBALL}" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  $SUDO install -o root -g root -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"
  success "Helm installed: $(helm version --short)"
fi

# ─── 8. Go ───────────────────────────────────────────────────────────────────
step "8/8  Go ${GO_VERSION}"

GOROOT="/usr/local/go"
GOBIN="${GOROOT}/bin/go"

if [[ -x "${GOBIN}" ]] && "${GOBIN}" version 2>/dev/null | grep -qF "go${GO_VERSION}"; then
  success "Go already at ${GO_VERSION}."
else
  log "Installing Go ${GO_VERSION} …"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz
  $SUDO rm -rf "${GOROOT}"
  $SUDO tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  success "Go installed: $("${GOBIN}" version)"
fi

export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"

GO_PATH_LINE='export PATH="/usr/local/go/bin:${HOME}/go/bin:${PATH}"'
for RC in "${HOME}/.bashrc" "${HOME}/.profile"; do
  if [[ -f "${RC}" ]] && ! grep -qF '/usr/local/go/bin' "${RC}"; then
    echo "${GO_PATH_LINE}" >> "${RC}"
    log "Added Go to PATH in ${RC}"
  fi
done

# ─── Final verification table ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Environment Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

print_tool() {
  local label="$1" bin="$2" ver_cmd="$3"
  if has "$bin"; then
    local ver
    ver="$(eval "$ver_cmd" 2>/dev/null | head -1 || echo 'unknown')"
    printf "  ${GREEN}✓${RESET}  %-22s  %s\n" "$label" "$ver"
  else
    printf "  ${RED}✗${RESET}  %-22s  NOT FOUND\n" "$label"
  fi
}

print_tool "Docker"          "docker"  "docker --version"
print_tool "Docker Compose"  "docker"  "docker compose version"
print_tool "kubectl"         "kubectl" "kubectl version --client 2>/dev/null | head -1"
print_tool "kind"            "kind"    "kind version"
print_tool "Helm"            "helm"    "helm version --short"
print_tool "Go"              "go"      "go version"

echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Source your shell:  source ~/.bashrc"
echo "  2. Run infrastructure: docker compose up -d  (from project root)"
echo "  3. Run setup scripts:  bash scripts/setup/01_init_postgres_source.sh"
echo ""
success "Environment bootstrap complete."
