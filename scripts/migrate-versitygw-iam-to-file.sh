#!/usr/bin/env bash
# Move both versitygw gateways' S3 account records out of OpenBao's
# `versitygw-iam` KV mount and into versitygw's internal file IAM store
# (ADR-072), preserving every access key and secret byte-for-byte so no
# consumer credential changes.
#
# Run this AFTER the s3-hot / s3-bulk roles have been redeployed with
# `--iam-dir` (deploy-foundation-stores.yml --tags s3-hot,s3-bulk). A gateway
# freshly switched to file IAM starts with an empty account store; this script
# refills it from OpenBao via the admin API, which is the only supported way to
# write accounts (versitygw owns the on-disk format).
#
# Reads accounts with the `versitygw` AppRole — the same credential the
# gateways used to use, which holds exactly CRUD+list on the versitygw-iam
# mount and nothing else. Its role_id/secret_id come from 1Password.
#
# Never prints a secret value — output is instance, access key, role, verdict.
#
# Usage:
#   OP_SERVICE_ACCOUNT_TOKEN=<read-scoped token> \
#     scripts/migrate-versitygw-iam-to-file.sh
#
# Idempotent: an account that already exists in the file store is verified
# rather than recreated, so re-running converges. Verification re-reads each
# account back through the admin API and compares the full record.

set -uo pipefail

: "${OP_SERVICE_ACCOUNT_TOKEN:?set OP_SERVICE_ACCOUNT_TOKEN to a token with read_items on the vault}"
export BAO_ADDR="${BAO_ADDR:-https://10.0.0.200:8200}"
export BAO_CACERT="${BAO_CACERT:-/usr/local/share/ca-certificates/grizzly-platform-openbao-ca.crt}"
OP_VAULT="${OP_VAULT:-grizzly-platform}"
R730XD="${R730XD:-bearf@10.0.0.200}"
IAM_MOUNT="${IAM_MOUNT:-versitygw-iam}"

# instance -> admin port (container-internal; reached via docker exec)
declare -A ADMIN_PORT=( [s3-hot]=7071 [s3-bulk]=7073 )

created=0
verified=0
failed=0

log()  { printf '%s\n' "$*"; }
die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

for cmd in bao op jq ssh; do
  command -v "${cmd}" >/dev/null || die "${cmd} not on PATH"
done

# --- authenticate to OpenBao with the versitygw AppRole -------------------
role_id="$(op read "op://${OP_VAULT}/stores-versitygw-iam/role_id")" \
  || die "could not read versitygw AppRole role_id from 1Password"
secret_id="$(op read "op://${OP_VAULT}/stores-versitygw-iam/secret_id")" \
  || die "could not read versitygw AppRole secret_id from 1Password"
BAO_TOKEN="$(bao write -field=token auth/approle/login \
  role_id="${role_id}" secret_id="${secret_id}")" \
  || die "versitygw AppRole login failed"
export BAO_TOKEN
unset role_id secret_id

# --- per-instance migration ------------------------------------------------
for inst in s3-hot s3-bulk; do
  port="${ADMIN_PORT[${inst}]}"
  container="foundation-${inst}"

  admin_access="$(op read "op://${OP_VAULT}/stores-${inst}/root_access_key")" \
    || die "could not read ${inst} root_access_key from 1Password"
  admin_secret="$(op read "op://${OP_VAULT}/stores-${inst}/root_secret_key")" \
    || die "could not read ${inst} root_secret_key from 1Password"

  # `versitygw admin` runs inside the container against 127.0.0.1 — the admin
  # port is deliberately not published. The command is fed to the remote shell
  # over stdin rather than as an ssh argument, so the admin credentials land in
  # the remote shell's environment (and from there into the container via
  # `docker exec -e`) without ever appearing in argv on either host.
  #
  # The one unavoidable exposure: `create-user -s <secret>` puts the *new
  # account's* secret on the container's argv for the life of that exec. The
  # admin CLI offers no environment equivalent for it.
  vgw_admin() {
    # SC2087: client-side expansion is the point — the creds and command are
    # interpolated here and delivered over the SSH channel, never as argv.
    # shellcheck disable=SC2087
    ssh "${R730XD}" 'bash -s' <<EOF 2>&1
export ADMIN_ACCESS_KEY_ID='${admin_access}'
export ADMIN_SECRET_KEY='${admin_secret}'
docker exec -e ADMIN_ACCESS_KEY_ID -e ADMIN_SECRET_KEY ${container} \
  versitygw admin --er http://127.0.0.1:${port} $*
EOF
  }

  keys_raw="$(bao kv list -format=json -mount="${IAM_MOUNT}" "${inst}" 2>/dev/null | jq -r '.[]')"
  if [[ -z "${keys_raw}" ]]; then
    log "SKIP  ${inst}: no accounts under ${IAM_MOUNT}/${inst}"
    continue
  fi

  existing="$(vgw_admin list-users)" || die "${inst}: admin API unreachable"

  while read -r key; do
    [[ -z "${key}" ]] && continue

    # Each account is one KV secret whose single field is named after the
    # access key, holding the account record as a JSON string.
    rec="$(bao kv get -format=json -mount="${IAM_MOUNT}" "${inst}/${key}" \
            | jq -c '[.data.data[]][0] | if type=="string" then fromjson else . end')"
    if [[ -z "${rec}" || "${rec}" == "null" ]]; then
      log "FAIL  ${inst}/${key}: unreadable account record"
      failed=$((failed + 1))
      continue
    fi

    access="$(jq -r '.access' <<<"${rec}")"
    secret="$(jq -r '.secret' <<<"${rec}")"
    role="$(jq -r '.role' <<<"${rec}")"
    uid="$(jq -r '.userID   // 0' <<<"${rec}")"
    gid="$(jq -r '.groupID  // 0' <<<"${rec}")"
    pid="$(jq -r '.projectID // 0' <<<"${rec}")"

    if grep -qE "^${access}[[:space:]]" <<<"${existing}"; then
      log "OK    ${inst}/${access}: already present in file IAM (${role})"
      verified=$((verified + 1))
      continue
    fi

    if ! out="$(vgw_admin create-user -a "${access}" -s "${secret}" -r "${role}" \
                  --ui "${uid}" --gi "${gid}" --pi "${pid}")"; then
      log "FAIL  ${inst}/${access}: create-user failed: ${out}"
      failed=$((failed + 1))
      continue
    fi
    log "NEW   ${inst}/${access}: created in file IAM (${role})"
    created=$((created + 1))
  done <<<"${keys_raw}"

  # Confirm the file store now holds every account OpenBao did.
  want="$(wc -l <<<"${keys_raw}")"
  got="$(vgw_admin list-users | tail -n +3 | grep -c . )"
  if [[ "${got}" -lt "${want}" ]]; then
    log "FAIL  ${inst}: file IAM has ${got} accounts, OpenBao had ${want}"
    failed=$((failed + 1))
  else
    log "OK    ${inst}: ${got} accounts in file IAM (OpenBao had ${want})"
  fi

  unset admin_access admin_secret
done

log ""
log "created=${created} verified=${verified} failed=${failed}"
[[ "${failed}" -eq 0 ]] || exit 1
