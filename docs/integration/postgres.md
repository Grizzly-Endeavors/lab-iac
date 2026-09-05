# Integration: PostgreSQL (foundation store)

**What you get:** a dedicated, non-superuser login role that **owns its own database** on the foundation PostgreSQL, reachable over the LAN at:

```
postgresql://<role>:<password>@10.0.0.200:5432/<database>
```

One foundation Postgres 16 instance on the R730xd backs every app's relational state (ADR-003, ADR-038). Each app gets its own role + DB; the role owns that DB and nothing else, so apps are isolated by ownership. This is the default home for durable relational data — **do not provision an in-cluster Postgres PVC.**

## When to use it

- **Use it** for any app needing SQL / relational state — the platform default per the storage rule in [CLAUDE.md](../../CLAUDE.md).
- **Not** for caching, sessions, rate-limit counters, or ephemeral queues → that's [Valkey](valkey.md). **Not** for blobs/large files → that's [S3](s3.md).

## Prerequisites

- Foundation Postgres running (`deploy-foundation-stores.yml`).
- A password in the 1Password item `stores-<app>` under field `db_password`. Generate it **without single quotes** (`openssl rand -base64 36`) — the provisioning play passes it through psql's `:'pw'` literal and a `'` breaks the quoting. (Secrets pattern: [secrets.md](secrets.md).)

## 1 — Provision the role + database

Provisioning is a small Ansible play per app, modeled on `setup-career-scanner-stores.yml`. Copy that play's DB block for a new app — it is idempotent and does exactly three things: create the login role (if absent), keep its password in sync with 1Password, and create the database `OWNER`ed by that role. The core of it:

```yaml
# psql -U postgres connects over the container's local socket (trust auth) —
# no superuser password needed on the host.
- name: Create the <app> login role
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      printf "CREATE ROLE <app> LOGIN PASSWORD :'pw';\n"
      | docker exec -i foundation-postgres
      psql -U postgres -v ON_ERROR_STOP=1 -v pw="$PGPW"
    executable: /bin/bash
  environment:
    PGPW: "{{ vault_<app>_db_password }}"
  when: <app>_role.stdout != "1"
  no_log: true

- name: Create the <app> database owned by the <app> role
  ansible.builtin.command: >-
    docker exec foundation-postgres
    psql -U postgres -v ON_ERROR_STOP=1
    -c "CREATE DATABASE <app> OWNER <app>"
  when: <app>_db.stdout != "1"
```

Run it against the R730xd:

```bash
ansible-playbook -i ansible/inventory ansible/playbooks/setup-<app>-stores.yml \
  --vault-password-file .vault_pass --tags db -v
```

The role is a **plain non-superuser that owns its DB** — your app runs its own migrations (including any `FORCE ROW LEVEL SECURITY`) at startup against a DB it fully controls, but it can't touch any other app's data.

## 2 — Wire it into your app

Land the password in your namespace with an `ExternalSecret` (full pattern in [secrets.md](secrets.md)):

```yaml
data:
  - secretKey: DB_PASSWORD
    remoteRef:
      key: stores-<app>/db_password
```

The key is `<item>/<field>` on the `onepassword` `ClusterSecretStore` — not a path plus a `property`.

Then build the DSN in your app from parts you already know — host `10.0.0.200`, port `5432`, db + user `<app>`, password from the synced secret:

```
postgresql://<app>:${DB_PASSWORD}@10.0.0.200:5432/<app>
```

Keep pool sizes sane: the instance is tuned for `max_connections = 100` shared across **all** apps. A handful of pooled connections per app is plenty; don't open 50.

## Extensions

The foundation image is stock `postgres:16` plus **pgvector** and **VectorChord**, built on the R730xd from `ansible/roles/r730xd-postgres/files/Dockerfile` with `vchord.so` preloaded ([ADR-072](../decisions/072-immich-on-foundation-stores-and-sso.md)). Together with the base image's contrib set, that makes these available to any database:

`vector`, `vchord` (vector search) · `cube`, `earthdistance` (geospatial) · `pg_trgm`, `unaccent` (text search)

Extensions are **per-database and opt-in** — availability is not installation. Your database has none until someone runs `CREATE EXTENSION`, and that needs superuser, which app roles deliberately do not have. So creating them is a task in your `setup-<app>-stores.yml`, run as `postgres`:

```yaml
- name: Create the extensions in the <app> database
  ansible.builtin.command: >-
    docker exec foundation-postgres
    psql -U postgres -d <app> -v ON_ERROR_STOP=1
    -c "CREATE EXTENSION IF NOT EXISTS {{ item }} CASCADE"
  loop:
    - vector
    - vchord
```

`setup-immich-stores.yml` is the worked example. Needing an extension the image doesn't carry means adding it to that Dockerfile and its pinned versions in the role's defaults, then re-running the play — check with a maintainer first, since it rebuilds and restarts the instance every app shares.

## Verify

```bash
# From the R730xd, confirm the role + DB exist and login works:
ssh r730xd "docker exec foundation-postgres psql -U postgres -tAc \
  \"SELECT rolname FROM pg_roles WHERE rolname='<app>'\""
ssh r730xd "docker exec foundation-postgres psql -U postgres -tAc \
  \"SELECT datname FROM pg_database WHERE datname='<app>'\""

# End-to-end from the cluster (exec into your pod):
psql "postgresql://<app>:$DB_PASSWORD@10.0.0.200:5432/<app>" -c '\conninfo'
```

## Troubleshoot

- **`password authentication failed`** — the role password in Postgres drifted from 1Password. Re-run the play with `--tags db`; the "keep password in sync" task runs unconditionally and `ALTER ROLE ... PASSWORD`s it back to the 1Password value.
- **`permission denied for schema public` on migrations** — you're connecting as a role that doesn't own the DB. Confirm the DB was created `OWNER <app>` and the app connects as `<app>`, not `postgres`.
- **`too many clients already`** — aggregate connections hit `max_connections = 100`. Shrink your pool; this is a shared instance.
- **Can't reach `10.0.0.200:5432` from a pod** — foundation Postgres binds the host LAN interface (host-network container); the cluster reaches it over the flat L2, not through a K8s Service. Check the pod actually has LAN egress and the container is up (`docker ps` on r730xd).

## See also

- [secrets.md](secrets.md) — how `db_password` reaches your namespace.
- `ansible/roles/r730xd-postgres/` + `ansible/playbooks/setup-career-scanner-stores.yml` — the role and the reference provisioning play.
- ADR [003](../decisions/003-foundation-stores-on-r730xd.md) (foundation stores), [038](../decisions/038-nextcloud-on-foundation-stores-and-sso.md) (the per-app role+DB pattern).
