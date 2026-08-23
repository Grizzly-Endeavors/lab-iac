#!/usr/bin/env bash
# Derive this control node's 1Password service-account tokens from the
# encrypted Ansible vault.
#
# Why this exists: the token files under ~/.config/op-tokens/ are a local
# cache, not a source of truth. The authoritative copies live in
# ansible/inventory/group_vars/all/vault.yml, which means a control node needs
# exactly one secret to bootstrap -- .vault_pass -- and derives everything else
# from it. That is what makes an offline or rebuilt control node a five-minute
# job rather than a credential-recovery exercise.
#
# Run it when standing up a control node, and on every control node after a
# token rotation: rotation rewrites vault.yml, which leaves the cached files
# stale. Tokens are never printed.
#
# Usage:
#   scripts/derive-op-tokens.sh
#
# Requires: .vault_pass at the repo root, ansible-vault, python3. Verification
# additionally needs `op`; without it the tokens are still written.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_FILE="${REPO_ROOT}/ansible/inventory/group_vars/all/vault.yml"
PASS_FILE="${REPO_ROOT}/.vault_pass"
DEST_DIR="${OP_TOKEN_DIR:-${HOME}/.config/op-tokens}"

# Token file name : the vault variable holding it.
TOKENS=(
  "ansible-reader:vault_op_service_account_token"
  "eso-reader:vault_op_eso_service_account_token"
  "operator:vault_op_operator_service_account_token"
)

log() { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v ansible-vault >/dev/null || die "ansible-vault not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
[[ -f "${VAULT_FILE}" ]] || die "vault file not found at ${VAULT_FILE}"
[[ -f "${PASS_FILE}" ]] || die \
  ".vault_pass not found at ${PASS_FILE} -- this is the one secret a control node cannot derive for itself; restore it from your password manager first"

umask 077
mkdir -p "${DEST_DIR}"

# Decrypt once and hand the plaintext to python over a pipe, so it is never
# written to disk. PyYAML is used rather than yq because the two yq forks
# (mikefarah, kislyuk) take incompatible filters and control nodes carry
# different ones; python3 + PyYAML ships with Ansible either way.
if ! ansible-vault view "${VAULT_FILE}" --vault-password-file "${PASS_FILE}" 2>/dev/null \
  | python3 -c '
import os, sys, yaml

dest = sys.argv[1]
pairs = [a.split(":", 1) for a in sys.argv[2:]]
data = yaml.safe_load(sys.stdin)

for name, var in pairs:
    value = (data.get(var) or "").strip()
    if not value:
        sys.exit(f"{var} is missing or empty in the vault")
    if not value.startswith("ops_"):
        sys.exit(f"{var} does not look like a service-account token")
    path = os.path.join(dest, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(value)
    print(f"wrote {path} ({len(value)} chars)")
' "${DEST_DIR}" "${TOKENS[@]}"; then
  die "could not derive tokens -- is .vault_pass correct, and does the vault carry all three variables?"
fi

# Verify each token still authenticates. `op service-account ratelimit` is the
# one call that does not itself count against the 1,000-requests-per-account
# daily quota, so this costs nothing.
if command -v op >/dev/null; then
  for entry in "${TOKENS[@]}"; do
    name="${entry%%:*}"
    token="$(cat "${DEST_DIR}/${name}")"
    if OP_SERVICE_ACCOUNT_TOKEN="${token}" \
        op service-account ratelimit >/dev/null 2>&1; then
      log "verified ${name}"
    else
      die "${name} did not authenticate -- expired or revoked. Re-mint per docs/runbooks/onepassword-quickref.md, then re-run this script"
    fi
  done
else
  die "op not on PATH -- tokens were written to ${DEST_DIR} but could not be verified; install op and re-run"
fi

unset token

log "done -- ${#TOKENS[@]} tokens in ${DEST_DIR}"
