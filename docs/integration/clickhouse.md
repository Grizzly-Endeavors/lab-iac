# Integration: ClickHouse (foundation store)

**What you get:** a dedicated login user that owns its own database on the foundation ClickHouse, reachable over the LAN at:

```
HTTP:   http://10.0.0.200:8123
Native: clickhouse://10.0.0.200:9000
```

One ClickHouse instance on the R730xd backs every app needing column-oriented analytical storage (ADR-064). Each app gets its own user + database; the user is granted only on that database, so apps are isolated the same way they are on Postgres.

## When to use it

- **Use it** for high-volume append-mostly analytical data — event/trace tables, time-series you need to aggregate over, anything where you scan many rows across few columns.
- **Not** for ordinary relational app state, foreign keys, or anything transactional → that's [postgres.md](postgres.md). ClickHouse has no real transactions and updates are expensive.
- **Not** for caching or queues → that's [valkey.md](valkey.md). **Not** for blobs → that's [s3.md](s3.md).

If you are reaching for ClickHouse because a Postgres table got big, measure first — Postgres handles a lot before this becomes the right answer.

## The one rule that will bite you

**This is a single node with no ClickHouse Keeper.** Replication is what needs Keeper, and one server means non-replicated MergeTree.

So **never issue `ON CLUSTER` DDL**, and never use `Replicated*` table engines. Both fail, and the failure is confusing — statements hang or report a missing coordination path rather than saying "there is no cluster." If your app has a "cluster mode" switch, turn it off: Langfuse, for example, needs `clickhouse.clusterEnabled: false`, and the chart defaults it to `true`.

## Prerequisites

- Foundation ClickHouse running (`deploy-foundation-stores.yml --tags clickhouse`).
- A password seeded in 1Password at `stores-<app>` under key `clickhouse_password`. Generate it as **hex** (`openssl rand -hex 24`) — hex avoids every quoting and URL-encoding question, and some clients build a connection URL from these parts.

## 1 — Provision the user + database

Provisioning is a small Ansible play per app, modeled on the ClickHouse block of `setup-langfuse-stores.yml`. It is idempotent and does three things: create the user, keep its password in sync with 1Password, and create the database plus a scoped grant. The core of it:

```yaml
- name: Create the <app> ClickHouse user
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      printf "CREATE USER IF NOT EXISTS <app> IDENTIFIED WITH sha256_password BY '%s';\n" "$CHPW"
      | docker exec -i foundation-clickhouse
      clickhouse-client --password "$ADMINPW" --multiquery
    executable: /bin/bash
  environment:
    CHPW: "{{ vault_<app>_clickhouse_password }}"
    ADMINPW: "{{ vault_clickhouse_password }}"
  no_log: true

- name: Create the <app> database and grant the <app> user
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      printf "CREATE DATABASE IF NOT EXISTS <app>;\nGRANT ALL ON <app>.* TO <app>;\n"
      | docker exec -i foundation-clickhouse
      clickhouse-client --password "$ADMINPW" --multiquery
    executable: /bin/bash
  environment:
    ADMINPW: "{{ vault_clickhouse_password }}"
  no_log: true
```

Statements go in on **stdin** so passwords never land in the host's process table.

Run it against the R730xd:

```bash
ansible-playbook -i ansible/inventory ansible/playbooks/setup-<app>-stores.yml \
  --vault-password-file .vault_pass --tags clickhouse -v
```

`GRANT ALL ON <app>.*` covers DDL, so your app can run its own migrations against a database it fully controls — and nothing else.

## 2 — Wire it into your app

Land the password in your namespace with an `ExternalSecret` against the `onepassword` `ClusterSecretStore`. The `remoteRef` key is `<item>/<field>`:

```yaml
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  data:
    - secretKey: clickhouse-password
      remoteRef:
        key: stores-<app>/clickhouse_password
```

Then point your client at it. Most libraries want the HTTP port; migration tools often want the native one:

```
CLICKHOUSE_URL=http://10.0.0.200:8123
CLICKHOUSE_MIGRATION_URL=clickhouse://10.0.0.200:9000
CLICKHOUSE_USER=<app>
CLICKHOUSE_DB=<app>
CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}
```

## Verify

```bash
# from the R730xd
ssh r730xd "sudo docker exec foundation-clickhouse clickhouse-client --user <app> --password '<pw>' --query 'SELECT 1'"

# from a pod, over the LAN
curl -s 'http://10.0.0.200:8123/?user=<app>&password=<pw>' --data-binary 'SELECT version()'
```

## Troubleshooting

- **`Authentication failed`** — the user is defined with `sha256_password`; confirm the value in 1Password matches what the app is sending, and that no trailing newline crept in.
- **`Not enough privileges`** — the grant is scoped to `<app>.*`. Querying `system.*` tables works, but touching another app's database will not.
- **DDL hangs or complains about coordination** — you used `ON CLUSTER` or a `Replicated*` engine. See "The one rule that will bite you" above.
- **`Memory limit exceeded`** — a single query is capped (see `clickhouse_max_memory_usage`), and the server as a whole is capped by `clickhouse_max_server_memory_bytes` in `group_vars/all/vars.yml`. Both are deliberate: this host also runs every other foundation store and the observability stack.

## See also

- [runbooks/langfuse.md](../runbooks/langfuse.md) — the first consumer, and a worked example of the whole pattern.
- [ADR-064](../decisions/064-langfuse-llm-observability.md) — why ClickHouse is here and why it is on the R730xd rather than in-cluster.
