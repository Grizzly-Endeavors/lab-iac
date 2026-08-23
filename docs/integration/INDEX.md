# Integration guides — index

One line per guide. See [`README.md`](README.md) for what an integration guide is and how it differs from a runbook or ADR.

## Foundation stores (durable app state, on the R730xd)

- [postgres.md](postgres.md) — get a scoped database + login role on the foundation PostgreSQL, and wire your app's connection string.
- [valkey.md](valkey.md) — use the shared kv-cache (Valkey) for caching, sessions, queues; connection, logical isolation, eviction caveats.
- [s3.md](s3.md) — get an S3 account + bucket on s3-hot or s3-bulk; endpoint, SDK config, hot-vs-bulk choice.
- [clickhouse.md](clickhouse.md) — get a scoped user + database on the foundation ClickHouse for column-oriented analytical data; includes the single-node/no-`ON CLUSTER` rule.

## Cross-cutting platform services

- [secrets.md](secrets.md) — land credentials in your namespace from 1Password via External Secrets (K8s) or `op` lookups (Ansible). **Read this first — every store guide builds on it.**
- [sso.md](sso.md) — put your app behind Authentik (OIDC for apps that speak it, forward-auth proxy for those that don't) and onboard people via the invite broker.
- [mail.md](mail.md) — send transactional email through Stalwart: get a submission credential and keep your from-address DMARC-aligned.
- [observability.md](observability.md) — emit logs (free), metrics, and traces; where each signal goes and how to see it in Grafana.
- [ntfy.md](ntfy.md) — send push notifications (and interactive approval buttons) from your app to phones/browsers/services via the shared ntfy service.
- [metabase.md](metabase.md) — expose your app's database to the shared Metabase for dashboards and ad-hoc exploration, through a read-only role.

## Delivery

- [deploy.md](deploy.md) — the app-delivery path: template repo → CI gate → Flux registration → ingress/TLS. How your app gets onto the cluster at all.
