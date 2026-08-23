# Integration: secrets (1Password + External Secrets)

**What you get:** application credentials delivered to your workload from the platform's single secrets source of truth — as a Kubernetes `Secret` synced into your namespace (K8s apps) or as Ansible vars (IaC), without any secret material ever landing in git.

Every platform secret lives in the **`grizzly-platform` 1Password vault**. You never talk to it directly from an app — a broker does: **External Secrets Operator (ESO)** for anything in the cluster, the **`op` CLI** for Ansible plays. This is the one pattern the store guides ([postgres](postgres.md), [valkey](valkey.md), [s3](s3.md)) all build on, so read this first.

> This repo is public. **No secret value ever goes in git** — not in a manifest, not in a values file, not in a comment. Everything routes through 1Password. See the [grizzly-platform-is-public](../../README.md) posture and [ADR-073](../decisions/073-retire-openbao.md).

## When to use it

- **Always**, for any credential, token, or key your app needs at runtime. There is no "just put it in a ConfigMap" exception.
- Use **ESO** if the consumer runs in the cluster. Use the **`op` lookup** path if the consumer is an Ansible play provisioning or configuring a host.

## Item layout

One item per domain, named `<domain>-<name>`, with field labels left as-is. **The field is part of the key** — there is no separate `property`:

```
remoteRef.key: stores-postgres/password
                └─ item ──┘ └ field ┘
```

| Domain | For |
|---|---|
| `stores-<app>` | Foundation-store grants an app consumes — DB password, S3 keys. Provisioned by that app's `setup-<app>-stores.yml`. |
| `apps-<app>` | App-owned runtime secrets that aren't foundation grants — session keys, third-party API keys. K8s-consumed only. First consumer was career-scanner ([ADR-048](../decisions/048-first-party-app-secrets-domain.md)). |
| `platform-<name>` | Platform-level shared credentials (Cloudflare, GitHub App, Authentik). |
| `cicd-<name>` | CI/CD credentials — cosign keys, runner tokens, build-cache S3. |

`op item list --vault grizzly-platform` is the authoritative list.

## 1 — Write the secret to 1Password

The `operator` service account token is the only one with write access. On a control node:

```bash
export OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/op-tokens/operator)"

# new item
op item create --category=password --vault=grizzly-platform --title='apps-<app>' \
  "session_secret=$(openssl rand -base64 36)" \
  'some_api_key=<value>'

# new field on an existing item
op item edit 'apps-<app>' --vault=grizzly-platform 'another_key=<value>'
```

Generate passwords **without single quotes** (`openssl rand -base64 36`) — a `'` breaks the psql `:'pw'` quoting used by the store-provisioning plays.

## 2a — Consume in Kubernetes (ESO)

The `onepassword` `ClusterSecretStore` already exists cluster-wide. Declare an `ExternalSecret` that names the keys you want; ESO materializes a native `Secret` in your namespace and keeps it in sync.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-secrets
  namespace: <app>
spec:
  refreshPolicy: OnChange
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: <app>-secrets          # the K8s Secret ESO creates
    creationPolicy: Owner
  data:
    - secretKey: SESSION_SECRET   # key in the resulting Secret
      remoteRef:
        key: apps-<app>/session_secret   # <item>/<field> — no property:
```

Then consume it in your Deployment the normal way (`envFrom: [{ secretRef: { name: <app>-secrets } }]` or a `secretKeyRef`). The `ExternalSecret` can live in your app's chart or, for infrastructure workloads, next to the HelmRelease in this repo and registered in the directory `kustomization.yaml`.

**Use `refreshPolicy: OnChange`, not a `refreshInterval`.** 1Password meters requests per *account* per day — 1,000, shared across every service account including Ansible's. Polling burns that budget for nothing; `OnChange` re-reads only when the ExternalSecret spec changes. The store's own daily validation is what detects a dead token.

**Need to reshape values** (e.g. build a `user:pass` string or a DSN from separate fields)? Use a `target.template` — `data` pulls the raw fields, the template composes the final env keys. The Stalwart `ExternalSecret` (`kubernetes/infrastructure/stalwart/externalsecret.yaml`) is the worked example: it builds `STALWART_RECOVERY_ADMIN: "admin:{{ .admin_password }}"` from a raw `admin_password`.

## 2b — Consume in Ansible (`op` lookup)

Add a `pre_tasks` include; every `vault_*` var is then an `op` lookup:

```yaml
pre_tasks:
  - name: Load 1Password-sourced platform secrets
    ansible.builtin.include_vars:
      file: "{{ playbook_dir }}/../vars/onepassword_secrets.yml"
    tags: [always]
```

Each key you consume needs a lookup block in `ansible/vars/onepassword_secrets.yml` defining `vault_<name>`. Lookups are **lazy** — a play only spends API calls on the variables it actually references — and fetch fresh on every run, so rotating a secret is just re-running the play.

Include it in `pre_tasks`, never in `group_vars/`: opt-in per playbook is what keeps every IaC play from being hard-coupled to 1Password availability.

## Verify

```bash
# The Secret ESO built exists and is populated:
kubectl get externalsecret <app>-secrets -n <app>          # STATUS should be SecretSynced
kubectl get secret <app>-secrets -n <app> -o jsonpath='{.data}' | jq 'keys'

# Force an immediate re-sync:
kubectl annotate externalsecret <app>-secrets -n <app> force-sync=$(date +%s) --overwrite
```

## Troubleshoot

- **`SecretSyncedError` / key not found** — almost always a bad `remoteRef.key`. It is `<item>/<field>`, one string: no `property:`, no path segments. Confirm the item and field exist with `op item get <item> --vault grizzly-platform`.
- **Secret exists but a field is empty** — the field label doesn't match. Labels are case- and space-sensitive; `op item get <item> --vault grizzly-platform --format json | jq '.fields[].label'`.
- **Provider errors across many ExternalSecrets at once** — check the shared quota before anything else: `op service-account ratelimit`. A per-account 24h cap exhausted by one consumer breaks the others.
- **`ClusterSecretStoreNotReady`** — the service account token is expired or revoked. 1Password caps token lifetime at 90 days. See [onepassword-quickref.md](../runbooks/onepassword-quickref.md#rotating-the-tokens).
- **Ansible can't find a var** — you added the item but not the lookup block in `onepassword_secrets.yml`.

## See also

- [onepassword-quickref.md](../runbooks/onepassword-quickref.md) — **operator** reference: tokens, rate limits, alert response, rotation, standing up a control node.
- ADR [073](../decisions/073-retire-openbao.md) (1Password as the secrets source of truth), [048](../decisions/048-first-party-app-secrets-domain.md) (app secrets domain).
