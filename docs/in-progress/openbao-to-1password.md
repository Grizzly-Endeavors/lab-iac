# Thread: OpenBao → 1Password for platform secrets

**Goal:** move platform secret delivery off OpenBao onto 1Password — the
`onepassword` ESO `ClusterSecretStore` for Kubernetes, and
`ansible/vars/onepassword_secrets.yml` lookups for Ansible. **OpenBao is being
retired outright**, not kept for the Ansible/AppRole path or other non-ESO
consumers.

## Done

- **Secret delivery is fully migrated.** Every ExternalSecret in the cluster
  references the `onepassword` store and none reference `openbao`; every
  playbook that reads platform secrets includes `onepassword_secrets.yml`, and
  `ansible/vars/openbao_secrets.yml` is gone.
- Operator runbook exists:
  [`runbooks/onepassword-quickref.md`](../runbooks/onepassword-quickref.md) —
  tokens, rate limits, alert response, rotation, and standing up a control node.
- Token age and store-validation alerting is in place.

## Remains

### 1. versitygw IAM — the blocker

OpenBao is still **load-bearing**, and not for secret delivery: both S3
gateways keep their IAM *account records* in it. They run with
`--iam-vault-endpoint-url https://10.0.0.200:8200 --iam-vault-mount-path
versitygw-iam` (see the `r730xd-s3-hot` and `r730xd-s3-bulk` roles), and every
S3 account lives under that mount.

**The `stores-versitygw-iam` item in 1Password does not mean this is done.**
That item holds the AppRole `role_id`/`secret_id` the gateways use to
*authenticate to* OpenBao. The credential moved to 1Password; the data it
unlocks did not. Reading the item's presence as "versitygw is migrated" and
switching OpenBao off would take out every S3 account on both gateways.

OpenBao cannot be switched off until that account store moves to another
versitygw IAM backend, and that migration touches the S3 layer the rest of the
platform sits on. Do this first — everything below is cleanup that is blocked
behind it.

### 2. Docs

- **[`integration/secrets.md`](../integration/secrets.md) is the important
  one** — the front door every other integration guide points at, still
  documenting the `openbao` store end to end including a key format that no
  longer works. Compare:
  - documented: `remoteRef: {key: grizzly-platform/stores/<app>, property: db_password}`
  - actual: `remoteRef: {key: stores-<app>/db_password}` — item/field, not
    path/property.

  A reader following it today writes an ExternalSecret that will not sync.
- Root [`INDEX.md`](../../INDEX.md) "Secrets (OpenBao)" still frames OpenBao as
  the source of truth for K8s and states Infisical holds the unseal keys.
- [`TOOLS.md`](../../TOOLS.md) still lists `bao` with a persistent root session
  as the secrets path.
- Assorted inline comments still say "from OpenBao" where the value now comes
  from 1Password (e.g. `authentik/blueprints/career-scanner.yaml`).

### 3. Decommission

Blocked behind (1). The unused `openbao` `ClusterSecretStore`; the
`r730xd-openbao` and `r730xd-openbao-agent` roles; the `openbao-*` playbooks;
the Prometheus targets and alert rules; the CA ConfigMap and
`scripts/fetch-openbao-ca.sh`; the Infisical unseal-key project; and the server
itself. The `openbao-*` runbooks retire with it. An ADR should record the
retirement and supersede [ADR-023](../decisions/023-self-hosted-openbao-on-r730xd.md)
and [ADR-024](../decisions/024-platform-secrets-on-openbao.md).

## Notes

New work uses 1Password (`stores-<app>` / `platform-<app>` items) —
[`integration/clickhouse.md`](../integration/clickhouse.md) and
`kubernetes/infrastructure/langfuse/externalsecret.yaml` are current worked
examples until `secrets.md` catches up.

Authoritative once this closes:
[`runbooks/onepassword-quickref.md`](../runbooks/onepassword-quickref.md) and a
rewritten [`integration/secrets.md`](../integration/secrets.md). Delete this
file and its `INDEX.md` line when the docs match the code.
