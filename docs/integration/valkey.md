# Integration: Valkey (kv-cache foundation store)

**What you get:** a shared, Redis-wire-compatible key-value store for caching, sessions, rate-limit counters, and light queues, reachable over the LAN at:

```
redis://:<password>@10.0.0.200:6379
```

The slot is named by function — **kv-cache** — because the backend is a swappable implementation detail; today it's Valkey (the Linux Foundation's Redis fork, wire/RDB/AOF-compatible). See [ADR-056](../decisions/056-redis-to-valkey.md).

## When to use it — and the one caveat that matters

Use it for data you can afford to lose: caches, session stores, ephemeral counters, short work queues. **Do not use it as a source of truth.** The instance runs `maxmemory 2gb` with `maxmemory-policy allkeys-lru`, so **any key can be evicted under memory pressure**, TTL or not. If losing a key would corrupt state, it belongs in [Postgres](postgres.md), not here. (AOF + RDB persistence is on, so the store survives a *restart* — but not eviction.)

For relational/durable data use [Postgres](postgres.md); for blobs use [S3](s3.md).

## What isolation you get

This is a **single shared instance with one `requirepass` password** (1Password item `stores-kv-cache`, field `password`) — there are no per-app ACL users today. Isolate your app's keyspace by convention:

- **Namespace every key** with an app prefix: `myapp:session:<id>`, `myapp:cache:<k>`. This is the portable choice and what most clients/libraries expect.
- Optionally pick a **logical DB number** (`redis://…:6379/3`, DBs 0–15) — but treat this as a courtesy, not a security boundary; the password is shared, so any consumer can `SELECT` any DB.

`FLUSHALL` and `FLUSHDB` are **renamed out** (disabled) on this instance precisely because it's shared — you cannot wipe another app's data, even by accident.

## Prerequisites

- kv-cache running (`deploy-foundation-stores.yml`).
- The shared password synced into your namespace from 1Password (pattern: [secrets.md](secrets.md)) — there's no per-app provisioning play to run; the credential already exists.

## Wire it into your app

Land the password with an `ExternalSecret`:

```yaml
data:
  - secretKey: REDIS_PASSWORD
    remoteRef:
      key: grizzly-platform/stores/kv-cache
      property: password
```

Then point your client at it (any Redis client works — Valkey is wire-compatible):

```
redis://:${REDIS_PASSWORD}@10.0.0.200:6379/0
```

Set a TTL on cache keys (`SET k v EX 3600`) so you're not relying on LRU eviction to clean up. Prefix everything with your app name.

## Verify

```bash
# From the R730xd:
ssh r730xd "docker exec foundation-kv-cache valkey-cli -a <password> PING"     # → PONG

# End-to-end from your pod (redis-cli / valkey-cli):
redis-cli -u redis://:$REDIS_PASSWORD@10.0.0.200:6379 SET myapp:health ok EX 30
redis-cli -u redis://:$REDIS_PASSWORD@10.0.0.200:6379 GET myapp:health
```

## Troubleshoot

- **`NOAUTH Authentication required`** — you didn't pass the password. The URL form is `redis://:<password>@host` (empty username, password after the colon).
- **`ERR unknown command 'FLUSHDB'`** — expected: destructive flushes are renamed out. Delete your own keys by prefix instead (`SCAN` + `DEL`).
- **Keys vanishing early** — LRU eviction under memory pressure, or another app filling the 2 GB. Anything you can't lose must move to Postgres; keep cache entries small and TTL'd.
- **`OOM command not allowed`** — the 2 GB ceiling is hit and the write can't evict enough. Investigate who's hogging memory (`INFO memory`, `--bigkeys`); raise `kv_cache_maxmemory` in the role only if the pressure is legitimate and sustained.

## See also

- [secrets.md](secrets.md) — how the password reaches your namespace.
- `ansible/roles/r730xd-kv-cache/` — the role, `valkey.conf.j2`, and tuning knobs.
- ADR [056](../decisions/056-redis-to-valkey.md) (Redis→Valkey), [003](../decisions/003-foundation-stores-on-r730xd.md) (foundation stores).
