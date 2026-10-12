#!/usr/bin/env bash
# =============================================================================
# Containers & Kubernetes Fundamentals — lab machine setup
#
#   Installs, on Debian/Ubuntu (22.04, 24.04 or similar):
#     * Docker Engine 28+ (docker-ce, docker-ce-cli, containerd.io,
#       docker-buildx-plugin, docker-compose-plugin) from the official apt repo
#     * kubectl (current stable channel from pkgs.k8s.io)
#     * kind    (latest release binary from GitHub)
#     * helm    (official get-helm-3 script)
#     * k9s     (optional, ON by default — set INSTALL_K9S=no to skip)
#     * VS Code + Docker/Kubernetes/YAML extensions (optional, OFF by default —
#       set INSTALL_VSCODE=yes to include it)
#     * git, curl, jq and friends
#
#   Usage:
#       bash ~/docker-kubernetes-training/labs/setup.sh
#       INSTALL_VSCODE=yes INSTALL_K9S=no bash setup.sh
#
#   The script is idempotent: run it as many times as you like. Anything that is
#   already present and recent enough is left alone.
#
#   It uses sudo for the system-wide bits and will prompt for your password.
#   Do NOT run it as root with `sudo bash setup.sh` — it needs to know your real
#   user name to add it to the `docker` group.
# =============================================================================

set -euo pipefail

KUBECTL_CHANNEL="${KUBECTL_CHANNEL:-v1.33}"   # pkgs.k8s.io minor-version channel
INSTALL_K9S="${INSTALL_K9S:-yes}"
INSTALL_VSCODE="${INSTALL_VSCODE:-no}"

# ---------------------------------------------------------------- helpers ----

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    warning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m    error: %s\033[0m\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ preflight ------

[[ "$(uname -s)" == "Linux" ]] || die "this script only supports Linux."

if [[ "${EUID}" -eq 0 && -z "${SUDO_USER:-}" ]]; then
  die "run this as your normal user (it calls sudo itself), not as root."
fi

TARGET_USER="${SUDO_USER:-$USER}"

if ! have sudo; then
  die "sudo is not installed. Install it (or ask your admin) and re-run."
fi

# shellcheck disable=SC1091
source /etc/os-release 2>/dev/null || die "/etc/os-release not found — unsupported distribution."

case "${ID}:${ID_LIKE:-}" in
  ubuntu:*|*:*ubuntu*) DISTRO="ubuntu" ;;
  debian:*|*:*debian*) DISTRO="debian" ;;
  *) die "unsupported distribution '${ID}'. This script targets Debian/Ubuntu." ;;
esac

# Ubuntu derivatives (Mint, Pop!_OS…) set UBUNTU_CODENAME; plain Debian does not.
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "${CODENAME}" ]] || die "cannot determine the distribution codename."

ARCH_DEB="$(dpkg --print-architecture)"          # amd64 | arm64
case "${ARCH_DEB}" in
  amd64) ARCH_ALT="x86_64" ;;
  arm64) ARCH_ALT="arm64"  ;;
  *) die "unsupported architecture '${ARCH_DEB}' (need amd64 or arm64)." ;;
esac

log "Lab machine setup"
info "distribution : ${PRETTY_NAME}  (${DISTRO}/${CODENAME})"
info "architecture : ${ARCH_DEB}"
info "user         : ${TARGET_USER}"
info "options      : k9s=${INSTALL_K9S} vscode=${INSTALL_VSCODE} kubectl=${KUBECTL_CHANNEL}"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------- 1. base packages ----

log "1/7 Base packages (git, curl, jq, …)"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  ca-certificates curl gnupg git jq apt-transport-https wget tar
sudo install -m 0755 -d /etc/apt/keyrings

# ------------------------------------------------------- 2. Docker Engine ----

log "2/7 Docker Engine"
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  info "adding Docker's GPG key"
  sudo curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
fi

DOCKER_LIST="deb [arch=${ARCH_DEB} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable"
if [[ "$(cat /etc/apt/sources.list.d/docker.list 2>/dev/null || true)" != "${DOCKER_LIST}" ]]; then
  info "writing /etc/apt/sources.list.d/docker.list"
  echo "${DOCKER_LIST}" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

sudo apt-get update -qq
sudo apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable the docker service (no systemd?)"

if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
  info "user ${TARGET_USER} is already in the 'docker' group"
else
  info "adding ${TARGET_USER} to the 'docker' group"
  sudo usermod -aG docker "${TARGET_USER}"
  NEEDS_RELOGIN=1
fi

# ------------------------------------------------------------- 3. kubectl ----

log "3/7 kubectl (${KUBECTL_CHANNEL} stable channel)"
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  info "adding the Kubernetes GPG key"
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBECTL_CHANNEL}/deb/Release.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  sudo chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

K8S_LIST="deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBECTL_CHANNEL}/deb/ /"
if [[ "$(cat /etc/apt/sources.list.d/kubernetes.list 2>/dev/null || true)" != "${K8S_LIST}" ]]; then
  info "writing /etc/apt/sources.list.d/kubernetes.list"
  echo "${K8S_LIST}" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
fi

sudo apt-get update -qq
sudo apt-get install -y -qq kubectl

# ---------------------------------------------------------------- 4. kind ----

log "4/7 kind"
KIND_WANTED="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
                 | jq -r '.tag_name' 2>/dev/null || true)"
[[ -n "${KIND_WANTED}" && "${KIND_WANTED}" != "null" ]] || {
  KIND_WANTED="v0.29.0"
  warn "could not read the latest kind release from GitHub — falling back to ${KIND_WANTED}"
}

KIND_HAVE="$(kind version 2>/dev/null | awk '{print $2}' || true)"
if [[ "${KIND_HAVE}" == "${KIND_WANTED}" ]]; then
  info "kind ${KIND_HAVE} already installed"
else
  info "installing kind ${KIND_WANTED} (linux/${ARCH_DEB})"
  tmp="$(mktemp -d)"
  curl -fsSLo "${tmp}/kind" "https://kind.sigs.k8s.io/dl/${KIND_WANTED}/kind-linux-${ARCH_DEB}"
  sudo install -m 0755 "${tmp}/kind" /usr/local/bin/kind
  rm -rf "${tmp}"
fi

# ---------------------------------------------------------------- 5. helm ----

log "5/7 helm"
if have helm; then
  info "helm already installed ($(helm version --short 2>/dev/null || echo unknown))"
else
  info "running the official get-helm-3 script"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | sudo bash >/dev/null
fi

# ----------------------------------------------------------------- 6. k9s ----

log "6/7 k9s (optional)"
if [[ "${INSTALL_K9S}" != "yes" ]]; then
  info "skipped (INSTALL_K9S=${INSTALL_K9S})"
elif have k9s; then
  info "k9s already installed ($(k9s version -s 2>/dev/null | head -1 || echo unknown))"
else
  K9S_TAG="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
               | jq -r '.tag_name' 2>/dev/null || true)"
  if [[ -z "${K9S_TAG}" || "${K9S_TAG}" == "null" ]]; then
    warn "could not read the latest k9s release — skipping (k9s is optional)"
  else
    info "installing k9s ${K9S_TAG} (Linux_${ARCH_ALT})"
    tmp="$(mktemp -d)"
    if curl -fsSLo "${tmp}/k9s.tar.gz" \
         "https://github.com/derailed/k9s/releases/download/${K9S_TAG}/k9s_Linux_${ARCH_ALT}.tar.gz"; then
      tar -xzf "${tmp}/k9s.tar.gz" -C "${tmp}" k9s
      sudo install -m 0755 "${tmp}/k9s" /usr/local/bin/k9s
    else
      warn "k9s download failed — skipping (k9s is optional)"
    fi
    rm -rf "${tmp}"
  fi
fi

# -------------------------------------------------------------- 7. VS Code ---

log "7/7 Visual Studio Code (optional)"
if [[ "${INSTALL_VSCODE}" != "yes" ]]; then
  info "skipped (set INSTALL_VSCODE=yes to install it)"
else
  if ! have code; then
    if [[ ! -f /etc/apt/keyrings/packages.microsoft.gpg ]]; then
      info "adding Microsoft's GPG key"
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/packages.microsoft.gpg
      sudo chmod a+r /etc/apt/keyrings/packages.microsoft.gpg
    fi
    CODE_LIST="deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main"
    if [[ "$(cat /etc/apt/sources.list.d/vscode.list 2>/dev/null || true)" != "${CODE_LIST}" ]]; then
      echo "${CODE_LIST}" | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
    fi
    sudo apt-get update -qq
    sudo apt-get install -y -qq code
  else
    info "VS Code already installed"
  fi

  if have code; then
    for ext in ms-azuretools.vscode-docker \
               ms-kubernetes-tools.vscode-kubernetes-tools \
               redhat.vscode-yaml; do
      if code --list-extensions 2>/dev/null | grep -qix "${ext}"; then
        info "extension ${ext} already installed"
      else
        info "installing extension ${ext}"
        code --install-extension "${ext}" --force >/dev/null 2>&1 \
          || warn "could not install ${ext} (are you on a headless machine?)"
      fi
    done
  fi
fi

# ---------------------------------------------------------------- versions ---

log "Installed versions"
docker --version                       2>/dev/null || warn "docker missing"
docker compose version                 2>/dev/null || warn "docker compose plugin missing"
docker buildx version                  2>/dev/null || warn "docker buildx plugin missing"
containerd --version                   2>/dev/null || true
kubectl version --client --output=yaml 2>/dev/null | grep -E 'gitVersion|kustomizeVersion' || warn "kubectl missing"
kind version                           2>/dev/null || warn "kind missing"
helm version --short                   2>/dev/null || warn "helm missing"
have k9s  && k9s version -s 2>/dev/null | head -3
have code && code --version 2>/dev/null | head -1
git --version

log "Done"
if [[ -n "${NEEDS_RELOGIN:-}" ]]; then
  cat <<EOF
    ${TARGET_USER} was added to the 'docker' group. Group membership is only
    picked up by NEW logins, so do one of these before running docker commands:

        newgrp docker      # applies to the current shell only
        # or log out and back in (best), or reboot the VM

EOF
fi
echo "    Next: verify with 'docker run --rm hello-world', then open labs/lab01.md"
