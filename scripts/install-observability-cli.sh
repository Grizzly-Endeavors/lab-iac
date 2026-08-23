#!/usr/bin/env bash
#
# Install CLI tools for the grizzly-platform observability stack
#
# Installs:
#   - logcli    (Loki log queries)
#   - promtool  (Prometheus rule validation, queries, debugging)
#   - amtool    (Alertmanager silence/alert management)
#
# Configures Fish shell environment variables for connecting to
# the R730xd observability stack.
#
# Usage:
#   ./scripts/install-observability-cli.sh
#
# Environment variables (override defaults from lab-network.env):
#   LOKI_ADDR          (default: http://<r730xd_ip>:3100)
#   PROMETHEUS_ADDR    (default: http://<r730xd_ip>:9090)
#   ALERTMANAGER_ADDR  (default: http://<r730xd_ip>:9093)
#   INSTALL_DIR        (default: /usr/local/bin)

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source lab network config (see ansible/group_vars/all/network.yml)
# shellcheck source=lab-network.env
[[ -f "${SCRIPT_DIR}/lab-network.env" ]] && . "${SCRIPT_DIR}/lab-network.env"

LOKI_ADDR="${LOKI_ADDR:-http://${R730XD_IP:-10.0.0.200}:3100}"
PROMETHEUS_ADDR="${PROMETHEUS_ADDR:-http://${R730XD_IP:-10.0.0.200}:9090}"
ALERTMANAGER_ADDR="${ALERTMANAGER_ADDR:-http://${R730XD_IP:-10.0.0.200}:9093}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *)       echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# =============================================================================
# Helpers
# =============================================================================

info()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()    { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m  !\033[0m $*"; }
fail()  { echo -e "\033[1;31m  ✗\033[0m $*"; exit 1; }

need_sudo() {
    if [[ "${INSTALL_DIR}" == /usr/local/bin ]] && [[ ${EUID} -ne 0 ]]; then
        echo "sudo"
    fi
}

fetch_latest_github_tag() {
    local repo="$1"
    curl -sI "https://github.com/${repo}/releases/latest" \
        | grep -i '^location:' \
        | sed 's|.*/||' \
        | tr -d '\r\n'
}

install_binary() {
    local name="$1" src="$2"
    chmod +x "${src}"
    $(need_sudo) install -m 0755 "${src}" "${INSTALL_DIR}/${name}"
    ok "${name} installed to ${INSTALL_DIR}/${name}"
}

# =============================================================================
# logcli (Loki)
# =============================================================================

install_logcli() {
    info "Installing logcli (Loki CLI)..."

    local tag
    tag="$(fetch_latest_github_tag grafana/loki)"
    [[ -z "${tag}" ]] && fail "Could not determine latest Loki release"

    local url="https://github.com/grafana/loki/releases/download/${tag}/logcli-linux-${ARCH_SUFFIX}.zip"
    info "  Downloading ${tag}..."
    curl -sL "${url}" -o "${TMPDIR}/logcli.zip"
    unzip -qo "${TMPDIR}/logcli.zip" -d "${TMPDIR}"
    install_binary "logcli" "${TMPDIR}/logcli-linux-${ARCH_SUFFIX}"
}

# =============================================================================
# promtool (Prometheus)
# =============================================================================

install_promtool() {
    info "Installing promtool (Prometheus CLI)..."

    local tag
    tag="$(fetch_latest_github_tag prometheus/prometheus)"
    [[ -z "${tag}" ]] && fail "Could not determine latest Prometheus release"

    local version="${tag#v}"
    local url="https://github.com/prometheus/prometheus/releases/download/${tag}/prometheus-${version}.linux-${ARCH_SUFFIX}.tar.gz"
    info "  Downloading ${tag}..."
    curl -sL "${url}" | tar xz -C "${TMPDIR}"
    install_binary "promtool" "${TMPDIR}/prometheus-${version}.linux-${ARCH_SUFFIX}/promtool"
}

# =============================================================================
# amtool (Alertmanager)
# =============================================================================

install_amtool() {
    info "Installing amtool (Alertmanager CLI)..."

    local tag
    tag="$(fetch_latest_github_tag prometheus/alertmanager)"
    [[ -z "${tag}" ]] && fail "Could not determine latest Alertmanager release"

    local version="${tag#v}"
    local url="https://github.com/prometheus/alertmanager/releases/download/${tag}/alertmanager-${version}.linux-${ARCH_SUFFIX}.tar.gz"
    info "  Downloading ${tag}..."
    curl -sL "${url}" | tar xz -C "${TMPDIR}"
    install_binary "amtool" "${TMPDIR}/alertmanager-${version}.linux-${ARCH_SUFFIX}/amtool"
}

# =============================================================================
# Fish shell configuration
# =============================================================================

configure_fish() {
    info "Configuring Fish shell environment..."

    if ! command -v fish &>/dev/null; then
        warn "Fish shell not found — skipping env config. Set these manually:"
        echo "  LOKI_ADDR=${LOKI_ADDR}"
        echo "  ALERTMANAGER_URL=${ALERTMANAGER_ADDR}"
        return
    fi

    fish -c "set -Ux LOKI_ADDR ${LOKI_ADDR}" 2>/dev/null
    ok "LOKI_ADDR=${LOKI_ADDR}"

    fish -c "set -Ux ALERTMANAGER_URL ${ALERTMANAGER_ADDR}" 2>/dev/null
    ok "ALERTMANAGER_URL=${ALERTMANAGER_ADDR}"

    # promtool uses --prometheus.url flag, no env var needed
}

# =============================================================================
# amtool configuration
# =============================================================================

# amtool does NOT read ALERTMANAGER_URL -- it takes --alertmanager.url or reads
# this config file. Without it, a bare `amtool alert query` fails with
# "required flag --alertmanager.url not provided" even though the environment
# variable is set, which reads as a broken install rather than a missing flag.
configure_amtool() {
    info "Configuring amtool..."

    local cfg_dir="${HOME}/.config/amtool"
    local cfg="${cfg_dir}/config.yml"

    mkdir -p "${cfg_dir}"
    printf 'alertmanager.url: %s\n' "${ALERTMANAGER_ADDR}" > "${cfg}"
    ok "${cfg} -> ${ALERTMANAGER_ADDR}"
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "Observability CLI Installer"
echo "==========================="
echo "  Target: ${INSTALL_DIR}"
echo "  Arch:   linux/${ARCH_SUFFIX}"
echo ""

install_logcli
install_promtool
install_amtool
configure_fish
configure_amtool

echo ""
info "Done! Quick start:"
echo ""
echo "  # Tail all container logs"
echo "  logcli query '{job=\"docker\"}' --tail"
echo ""
echo "  # Query Prometheus"
echo "  promtool query instant ${PROMETHEUS_ADDR} 'up'"
echo ""
echo "  # List active alerts"
echo "  amtool alert --alertmanager.url=${ALERTMANAGER_ADDR}"
echo ""
echo "  # Silence an alert for 2 hours"
echo "  amtool silence add --alertmanager.url=${ALERTMANAGER_ADDR} alertname=PrometheusWatchdog --duration=2h"
echo ""
