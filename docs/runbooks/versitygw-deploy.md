# versitygw — Deployment & Operations Runbook

Deployment/operations counterpart to [`versitygw-cli.md`](versitygw-cli.md) (which is "how to drive the tool"). This page is "how the stores are stood up and operated here" ([ADR-055](../decisions/055-s3-object-store-versitygw.md)).

## What's deployed

Two versitygw gateways run as Docker Compose services on the R730xd, each owned by a systemd unit (lifecycle + boot-ordering mount guard):

| Instance | Role | Backing | S3 API | Admin | Metrics | Data root |
|---|---|---|---|---|---|---|
| **s3-hot** | `r730xd-s3-hot` | ZFS `tank/foundation/s3-hot` (recordsize 1M) | `10.0.0.200:7070` | `:7071` (container-internal) | `:9102` | `/mnt/zfs/foundation/s3-hot/{data,versions}` |
| **s3-bulk** | `r730xd-s3-bulk` | MergerFS+SnapRAID `/mnt/pool` | `10.0.0.200:7072` | `:7073` (container-internal) | `:9103` | `/mnt/pool/foundation/s3-bulk/{data,versions}` |

- **IAM:** versitygw's internal file store ([ADR-072](../decisions/072-versitygw-iam-on-internal-file-store.md)) — `--iam-dir`, one directory per gateway on the ZFS dataset `tank/foundation/versitygw-iam/{s3-hot,s3-bulk}`, mounted into each container as `/data/iam`. No external dependency. Root creds per instance in the 1Password items `stores-s3-hot` / `stores-s3-bulk` (`root_access_key`, `root_secret_key`); every other account is created through the admin API.
- **Config:** 100% flags/env (versitygw is stateless) rendered into `/opt/foundation/<inst>/docker-compose.yml` (secrets in a sibling `versitygw.env`, 0600). No live reload — a config change is `systemctl restart foundation-<inst>`.
- **Metrics:** versitygw has no native Prometheus endpoint, so each gateway has a `statsd-exporter` sidecar (StatsD → Prometheus, scraped at `:9102`/`:9103`). The statsd→prom mapping (`/etc/versitygw/<inst>/statsd-mapping.yml`) is a pass-through: versitygw emits well-labelled counters — `versitygw_{bytes_read,bytes_written,success_count,failed_count,object_created_count,object_removed_count}` with `action`/`api`/`bucket`/`method`/`status` labels — so no per-metric mapping is needed. (There is no request-latency or bucket-size gauge.) These feed the `foundation-stores` Grafana dashboard.

## Standing up from scratch (order matters)

```
# 1. ZFS dataset for the hot tier (adds tank/foundation/s3-hot):
ansible-playbook -i ansible/inventory ansible/playbooks/r730xd-zfs.yml \
  --vault-password-file .vault_pass

# 2. Deploy the gateways (the roles create the IAM dirs under the dataset):
ansible-playbook -i ansible/inventory ansible/playbooks/deploy-foundation-stores.yml \
  --tags s3-hot,s3-bulk --vault-password-file .vault_pass

# 3. Monitoring (statsd-exporter scrape jobs + /health blackbox probes).
#    Use the full inventory dir (not just r730xd.yml) — the prometheus template
#    reads the k8s_control_plane group from lab-nodes.yml:
ansible-playbook -i ansible/inventory ansible/playbooks/deploy-observability.yml \
  --tags prometheus --limit r730xd --vault-password-file .vault_pass
```

Note that step 1 also creates `tank/foundation/versitygw-iam`, which both gateways mount — the hot tier is not the only consumer of that play.

Health check after: `curl http://10.0.0.200:7070/health` and `:7072/health` → 200 (a 200 proves the startup `user.*` xattr validation passed — versitygw refuses to start without it).

## Provisioning a consumer account (per app)

Accounts are created against a running gateway's **admin port**, in-container (the admin port isn't LAN-published). Use the instance's root creds as admin creds:

```
AK=$(op read op://grizzly-platform/stores-s3-hot/root_access_key)
SK=$(op read op://grizzly-platform/stores-s3-hot/root_secret_key)
# userplus = may create/own its own buckets; user = may only use granted buckets
docker exec -e ADMIN_ACCESS_KEY_ID=$AK -e ADMIN_SECRET_KEY=$SK foundation-s3-hot \
  versitygw admin --er http://127.0.0.1:7071 create-user -a <access> -s <secret> -r userplus
docker exec -e ADMIN_ACCESS_KEY_ID=$AK -e ADMIN_SECRET_KEY=$SK foundation-s3-hot \
  versitygw admin --er http://127.0.0.1:7071 list-users
```

The account lands in the gateway's own `users.json` under `/mnt/zfs/foundation/versitygw-iam/<inst>/`. Confirm with `list-users` above, never by reading the file. New (uncached) keys resolve immediately; *changes* to an existing key lag up to `--iam-cache-ttl` (120s).

## Troubleshooting

- **Gateway won't start / unit failed:** `systemctl status foundation-<inst>`, then `cd /opt/foundation/<inst> && docker compose up -d` to see the pull/run error. `docker logs foundation-<inst>`. Startup fails closed if a required mount is missing or the backing FS lacks `user.*` xattr support.
- **Gateway healthy but every non-root key 403s:** the IAM dataset didn't mount and the gateway came up with an empty account store. `findmnt /mnt/zfs/foundation/versitygw-iam`, then restart the unit. The unit's `RequiresMountsFor` is meant to prevent this.
- **Auth works but S3 request 403s right after a key change:** IAM cache (`--iam-cache-ttl`, 120s). Wait it out or restart.
- **Dependencies:** the data mount (ZFS for s3-hot, MergerFS for s3-bulk) and the ZFS IAM mount, both of which the systemd unit's `RequiresMountsFor` refuses to start without. Nothing external.
- **Recovery:** stateless — `systemctl restart foundation-<inst>` (or reschedule) loses nothing; all state is the backend dir + the IAM dir.
