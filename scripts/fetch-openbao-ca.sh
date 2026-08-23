#!/usr/bin/env bash
# Fetch the current OpenBao CA certificate from r730xd and embed it in
# the committed ConfigMap at
# kubernetes/infrastructure/external-secrets/openbao-ca-configmap.yaml.
#
# Why this exists: the ConfigMap is reconciled by Flux, so the CA PEM
# must live in git. The CA is generated on r730xd by the r730xd-openbao
# role and rotates every ~10 years. This script pulls the current PEM
# over ssh and updates the ConfigMap in place. The local trust-store
# install also ensures no orphaned lab-iac-openbao-ca.crt lingers.
#
# Also writes the CA to the controller's trust store path so
# community.hashi_vault lookups from Ansible can verify it (the
# openbao_tls_ca_path default in vars.yml). Requires sudo on the
# controller for the trust-store write.
#
# Usage:
#   scripts/fetch-openbao-ca.sh
#
# Idempotent: if the CA hasn't changed, the ConfigMap is left alone.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
CONFIGMAP="${REPO_ROOT}/kubernetes/infrastructure/external-secrets/openbao-ca-configmap.yaml"
CA_SRC="r730xd:/etc/openbao/tls/ca.crt"
CA_TRUST_DEST="/usr/local/share/ca-certificates/grizzly-platform-openbao-ca.crt"

log()  { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

[[ -r "${CONFIGMAP}" ]] || die "${CONFIGMAP} not found"
command -v ssh >/dev/null || die "ssh not on PATH"
command -v sed >/dev/null || die "sed not on PATH"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
TMP_CA="${TMPDIR}/ca.crt"

# /etc/openbao/tls/ is 0750 root, so a non-root SSH user can't scp the
# file directly. Use sudo cat through ssh — the CA is public (it's the
# trust anchor, not the signing key), so piping it over ssh is fine.
log "fetching CA from r730xd via sudo cat"
CA_HOST="${CA_SRC%%:*}"
CA_PATH="${CA_SRC#*:}"
# shellcheck disable=SC2029 # CA_PATH is a local script constant, not remote/user input — client-side expansion is intended
ssh "${CA_HOST}" "sudo cat ${CA_PATH}" > "${TMP_CA}" \
    || die "ssh fetch failed — check ssh ${CA_HOST} + passwordless sudo"
[[ -s "${TMP_CA}" ]] || die "fetched CA is empty"
grep -q 'BEGIN CERTIFICATE' "${TMP_CA}" || die "fetched CA is not PEM-looking"

# --- embed into ConfigMap ---------------------------------------------
log "embedding into ${CONFIGMAP}"
# Re-render the ConfigMap: everything before `data:` stays, then
# `  ca.crt: |\n<indented PEM>`, no other data keys.
HEADER="$(awk '/^data:/{print; exit} {print}' "${CONFIGMAP}")"
INDENTED_CA="$(sed 's/^/    /' "${TMP_CA}")"

{
    printf '%s\n' "${HEADER}"
    printf '  ca.crt: |\n'
    printf '%s\n' "${INDENTED_CA}"
} > "${TMPDIR}/new.yaml"

if cmp -s "${CONFIGMAP}" "${TMPDIR}/new.yaml"; then
    log "CA unchanged; ConfigMap already current"
else
    mv "${TMPDIR}/new.yaml" "${CONFIGMAP}"
    log "updated ${CONFIGMAP} — commit + push to let Flux reconcile"
fi

# --- install into controller trust store ------------------------------
CA_TRUST_LEGACY="/usr/local/share/ca-certificates/lab-iac-openbao-ca.crt"

if [[ -w "$(dirname "${CA_TRUST_DEST}")" ]] 2>/dev/null || sudo -n true 2>/dev/null; then
    log "installing CA into controller trust store at ${CA_TRUST_DEST}"
    if [[ -w "$(dirname "${CA_TRUST_DEST}")" ]]; then
        cp "${TMP_CA}" "${CA_TRUST_DEST}"
        rm -f "${CA_TRUST_LEGACY}"
    else
        sudo cp "${TMP_CA}" "${CA_TRUST_DEST}"
        sudo rm -f "${CA_TRUST_LEGACY}"
    fi
    # Copying the PEM is only half the install -- the trust store is not
    # consulted until update-ca-certificates rebuilds the bundle. Do not guard
    # this on `command -v`: update-ca-certificates lives in /usr/sbin, which is
    # not on a non-root user's PATH, so the check silently fails and leaves the
    # CA inert. That surfaces much later as an "unknown authority" TLS error
    # against OpenBao, a long way from the cause.
    if [[ "${EUID}" -eq 0 ]]; then
        update-ca-certificates >/dev/null \
            || die "update-ca-certificates failed -- CA copied but not active"
    else
        sudo update-ca-certificates >/dev/null \
            || die "update-ca-certificates failed -- CA copied but not active"
    fi
else
    log "skipped trust-store install (no sudo); copy manually:"
    log "  sudo cp <controller-accessible-path>/ca.crt ${CA_TRUST_DEST}"
    log "  sudo update-ca-certificates"
fi

log "done"
