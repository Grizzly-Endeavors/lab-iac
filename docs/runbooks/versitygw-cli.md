# versitygw — Operating Reference

How to drive [Versity S3 Gateway](https://github.com/versity/versitygw) (`versitygw`) — the S3 engine on the foundation stores ([ADR-055](../decisions/055-s3-object-store-versitygw.md)). versitygw is a **stateless** S3 gateway: it holds no authoritative state of its own, translates the S3 API into plain POSIX file operations on a backing filesystem, and delegates durability to that filesystem (ZFS / MergerFS+SnapRAID). There is **no config database and no config file** — the entire configuration is CLI flags / environment variables, so every config change is "restart the process with new flags". This is the opposite of Stalwart's DB-backed model ([`stalwart-cli.md`](stalwart-cli.md)); do not look for a settings store here.

This page is the "how to drive the tool" reference. The migration/deployment story (Ansible roles, ESO wiring, consumer cutover, instance rename to `s3-hot`/`s3-bulk`) lives in [ADR-055](../decisions/055-s3-object-store-versitygw.md) and (once built) its deployment runbook.

> **Keep this current.** This runbook exists so sessions stop reverse-engineering versitygw. Whenever you learn a new surface (a flag, an on-disk shape, an object-lock quirk, a working recipe) or find something here has gone stale (a version bump changes behaviour, a flag is renamed, a documented shape stops working), **update this file in the same change** — add the recipe, correct the drift, bump the version note. A wrong entry here is worse than a missing one: it sends the next session down a false path. When in doubt, re-verify against `--help` and record what you found. Everything below was verified live against **v1.6.0** on the R730xd MergerFS pool on 2026-07-06 (the ADR-055 validation spike).

## Mental model (read this first)

- **Backend = a directory tree.** You point versitygw at one top-level directory. Each immediate sub-directory is a **bucket**; every file/dir below a bucket is an **object**, at its literal key path (the key is split on `/`). `s3://app-data/nested/path/big.bin` is the file `<root>/app-data/nested/path/big.bin`, byte-for-byte. No encoding, no packing, no proprietary layout. This is *the* reason it was chosen over SeaweedFS (which packs many objects into mutable volume files and defeats SnapRAID).
- **Metadata rides in POSIX extended attributes** (`user.*` xattrs) on each object/bucket file — etag, checksum, content-type, version-id, retention, ACL. The backing filesystem **must support xattrs**; versitygw validates this at startup and refuses to run otherwise. (ext4 under MergerFS passes `user.*` xattrs through — verified.) Alternative metadata modes: `--sidecar <dir>` (store metadata in a parallel dir instead of xattrs) or `--nometa` (drop metadata entirely — don't).
- **Stateless ⇒ HA is just "run more copies."** Multiple gateway processes over the same backend directory are valid. There is no metadata DB to corrupt (the Garage RF=1 risk that ADR-055's fallback carried does not exist here).
- **IAM is pluggable, and it is a *store*, not an identity source.** Root credentials are always CLI/env. Additional accounts are created, updated and deleted by versitygw itself through its admin API, into one of: **internal file (`--iam-dir`, our choice)**, LDAP, HashiCorp Vault / OpenBao, S3, FreeIPA. Whatever backs it must accept writes and return the S3 secret in cleartext for SigV4 verification. See [IAM (internal file store)](#iam-internal-file-store).

## Invocation

versitygw ships as a container: **`ghcr.io/versity/versitygw:v1.6.0`** (also on Docker Hub as `versity/versitygw`). The binary's argument shape is:

```
versitygw [global options] <backend> [backend options] [backend args]
```

Every flag has a `VGW_*` (or `ROOT_*` / `ADMIN_*`) environment-variable equivalent — prefer env for anything sensitive so it stays off the process argv. Backend is one of `posix` (ours), `scoutfs`, `s3` (proxy to another S3), `azure`. The posix backend's one positional arg is the gateway root directory.

Minimal posix launch (internal file IAM, versioning on), as used in the spike:

```
docker run -d --name versitygw \
  -p 7070:7070 -p 7071:7071 \
  -e ROOT_ACCESS_KEY=<root-access> -e ROOT_SECRET_KEY=<root-secret> \
  -v /mnt/pool/foundation/s3-bulk/data:/data/s3 \
  -v /mnt/pool/foundation/s3-bulk/versions:/data/versions \
  -v /mnt/pool/foundation/s3-bulk/iam:/data/iam \
  ghcr.io/versity/versitygw:v1.6.0 \
  --port :7070 --admin-port :7071 --health /health --iam-dir /data/iam \
  posix --versioning-dir /data/versions /data/s3
```

Notes:
- **Root creds via `ROOT_ACCESS_KEY` / `ROOT_SECRET_KEY`** (env), never on argv. The `--access` / `--secret` flags also read `$ROOT_ACCESS_KEY_ID` / `$ROOT_SECRET_ACCESS_KEY`. The root account is the bootstrap admin and always exists regardless of IAM backend.
- **`--admin-port` is separate from the S3 port.** The admin API (user management) listens there. If you omit it, admin shares the S3 port.
- **`--health /health`** turns on a plain `GET /health → 200` liveness endpoint (used by the readiness probe).
- **Pin the tag; verify current stable before bumping.** As of 2026-07-06 stable is v1.6.0 (2026-06-26); the project is actively maintained (multiple releases/month through mid-2026, Apache-2.0). Check [releases](https://github.com/versity/versitygw/releases) before changing the pin.
- **Config changes require a process restart** — there is no live reload (stateless design). Restart the container; the backend directory and the IAM store persist across restarts.

## Global options (the ones that matter here)

Full list is `versitygw --help`. The subset we actually touch:

| Flag | Env | Default | Purpose |
|---|---|---|---|
| `--port, -p` | `VGW_PORT` | `:7070` | S3 listen address |
| `--admin-port, --ap` | `VGW_ADMIN_PORT` | (= S3 port) | Admin API listen address |
| `--region` | `VGW_REGION` | `us-east-1` | S3 region string |
| `--access` / `--secret` | `ROOT_ACCESS_KEY[_ID]` / `ROOT_SECRET_[ACCESS_]KEY` | — | Root account creds |
| `--cert` / `--key` | `VGW_CERT` / `VGW_KEY` | — | TLS cert + key (PEM file paths) for the S3 listener |
| `--health` | `VGW_HEALTH` | — | Health endpoint path (e.g. `/health`) |
| `--readonly` | `VGW_READ_ONLY` | false | Gateway-wide read-only |
| `--iam-cache-ttl` | `VGW_IAM_CACHE_TTL` | `120` | **Seconds an IAM account is cached** — see gotcha below |
| `--iam-cache-disable` | `VGW_IAM_CACHE_DISABLE` | false | Disable IAM caching (immediate account changes) |
| `--iam-debug` | `VGW_IAM_DEBUG` | false | Log IAM backend resolution — reach for this when auth misbehaves |
| `--debug` | `VGW_DEBUG` | false | Verbose request/signing debug |
| `--quiet, -q` | `VGW_QUIET` | false | Silence per-request stdout logging |
| `--access-log` | `VGW_ACCESS_LOG` | — | Access-log file path |
| `--metrics-statsd-servers, --mss` | `VGW_METRICS_STATSD_SERVERS` | — | StatsD metric sinks (also dogstatsd via `--mds`) |
| `--event-webhook-url, --ewu` | `VGW_EVENT_WEBHOOK_URL` | — | Bucket-event notifications (also kafka/nats/rabbitmq) |
| `--disable-acl, --noacl` | `VGW_DISABLE_ACL` | false | Turn off bucket ACL processing |

## posix backend options

`versitygw posix --help`. Positional arg = gateway root dir.

| Flag | Env | Default | Purpose |
|---|---|---|---|
| `--versioning-dir <dir>` | `VGW_VERSIONING_DIR` | (off) | **Enables bucket versioning**; non-current versions are stored under this *separate* dir (see [Versioning](#versioning)). Marked experimental upstream but validated working. |
| `--sidecar <dir>` | `VGW_META_SIDECAR` | (off) | Store object metadata in a parallel sidecar dir instead of xattrs — use only if the backing FS can't do xattrs. |
| `--nometa` | `VGW_META_NONE` | false | Disable metadata storage entirely. Don't — breaks etag/checksum/versioning. |
| `--dir-perms <octal>` | `VGW_DIR_PERMS` | `0755` | Permissions for new directories. |
| `--chuid` / `--chgid` | `VGW_CHOWN_UID` / `VGW_CHOWN_GID` | false | chown new files to the client account's UID/GID (multi-tenant POSIX ownership). |
| `--bucketlinks` | `VGW_BUCKET_LINKS` | false | Treat symlinked dirs at the top level as buckets. |
| `--concurrency <n>` | `VGW_POSIX_CONCURRENCY` | `5000` | Max concurrent FS actions. |
| `--disable-copy-file-range` | `VGW_DISABLE_COPY_FILE_RANGE` | false | Copy multipart parts in userspace instead of `copy_file_range(2)`. **Set this if the backend is NFS-mounted and multipart completion hangs.** Our gateway writes to a *local* MergerFS mount (not NFS), so this is off — but the pool *also* exports NFS to other clients, so remember the flag exists if the topology ever changes. |
| `--disableotmp` | `VGW_DISABLE_OTMP` | false | Disable `O_TMPFILE` for new-object staging (needed on filesystems without O_TMPFILE support). |

## On-disk layout (verified — the SnapRAID-compatibility claim)

Backend root after a few operations:

```
<root>/app-data/                         ← bucket = top-level dir
<root>/app-data/small.txt                ← object = plain file at literal key path
<root>/app-data/nested/path/big.bin      ← key "nested/path/big.bin" → nested dirs
<root>/app-data/.sgwtmp/multipart/       ← transient multipart staging (per-bucket)
```

Object bytes on disk are **identical** to the uploaded object (verified by md5). Metadata is in `user.*` xattrs:

- On an **object** file: `user.etag`, `user.checksums` (JSON; default algorithm is **CRC64NVME** in v1.6.0), `user.content-type`, and once versioning is on, `user.version-id` (a ULID). Delete markers carry `user.delete-marker`.
- On a **bucket** dir: `user.ownership` (e.g. `BucketOwnerEnforced`), `user.acl` (JSON: `{"Owner":...,"Grantees":[...]}`), and when object-lock is enabled, `user.bucket-lock` (JSON: `{"Enabled":true,"DefaultRetention":...}`). A retained object also gets `user.object-retention` (JSON: `{"Mode":...,"RetainUntilDate":...}`).

**Why this is SnapRAID-safe:** every object — current or historical — is exactly one file. versitygw never packs multiple objects into one mutable container file. The *current* object in the data dir is overwritten in place on PUT (a changed file, which SnapRAID re-syncs normally); *non-current versions* in the versioning dir are write-once immutable files (ideal for SnapRAID). The transient `.sgwtmp/` staging dir is cleaned on multipart completion. Contrast SeaweedFS (rejected) whose append-mutated volume files defeat SnapRAID entirely.

## Versioning

Enabled by giving the posix backend a `--versioning-dir` (separate from the gateway root). Then it's per-bucket via the standard S3 API:

```
aws s3api put-bucket-versioning --bucket app-data --versioning-configuration Status=Enabled
aws s3api list-object-versions  --bucket app-data --prefix ver.txt
aws s3api get-object            --bucket app-data --key ver.txt --version-id <ULID> out.bin
aws s3api delete-object         --bucket app-data --key ver.txt          # creates a delete marker
```

Verified behaviour: overwrites accumulate versions (version-ids are time-sortable ULIDs like `01KWWAGGWX…`); the latest lives in the data dir, non-current versions move to the versioning dir; fetch-by-version-id returns the exact old bytes; a keyless delete creates a delete-marker (latest) while prior versions survive; GET of the latest after a delete-marker returns `NoSuchKey` — all standard S3 semantics.

On-disk, non-current versions are sharded by the sha256 of the key:

```
<versioning-dir>/<bucket>/<2>/<2>/<2>/<sha256(key)>/<version-id>
# e.g. .../app-data/e1/6a/8c/e16a8cd4…757571/01KWWAGDADCR38MFPRNVN6PG1G
```

Each version file is immutable and named by its version-id.

## Object lock, retention & legal hold

Object-lock must be turned on **at bucket creation** (it force-enables versioning):

```
aws s3api create-bucket --bucket wormy --object-lock-enabled-for-bucket
aws s3api get-object-lock-configuration --bucket wormy         # → ObjectLockEnabled: Enabled

# GOVERNANCE / COMPLIANCE retention on a specific object version:
aws s3api put-object-retention  --bucket wormy --key x --retention Mode=GOVERNANCE,RetainUntilDate=2030-01-01T00:00:00Z
aws s3api get-object-retention  --bucket wormy --key x

# Legal hold (independent of retention):
aws s3api put-object-legal-hold --bucket wormy --key x --legal-hold Status=ON   # or OFF
aws s3api get-object-legal-hold --bucket wormy --key x
```

Verified: a version under retention refuses `delete-object` with `AccessDenied … object protected by object lock`; a version under legal hold refuses deletion until the hold is set `OFF`; releasing the hold then permits deletion.

> **⚠️ Caveat (v1.6.0, verified): `--bypass-governance-retention` is rejected even for the root account.** In real AWS, GOVERNANCE mode is meant to be overridable by a principal holding `s3:BypassGovernanceRetention`; here the bypass returned `AccessDenied`, so **GOVERNANCE effectively behaves like COMPLIANCE** — retention is absolute until `RetainUntilDate`. This is *safer*, not weaker, but it deviates from AWS semantics: do not rely on being able to bypass a governance lock to clean up early. Re-check against upstream on the next version bump and update this note.

## IAM (internal file store)

Accounts live in versitygw's own file store, one directory per gateway on a dedicated ZFS dataset ([ADR-072](../decisions/072-versitygw-iam-on-internal-file-store.md)):

| Gateway | `--iam-dir` (host path) | Mounted in container as |
|---|---|---|
| s3-hot | `/mnt/zfs/foundation/versitygw-iam/s3-hot` | `/data/iam` |
| s3-bulk | `/mnt/zfs/foundation/versitygw-iam/s3-bulk` | `/data/iam` |

The root account stays CLI/env (`ROOT_ACCESS_KEY` / `ROOT_SECRET_KEY`); every other account is managed through the admin API. There is nothing to authenticate to and no external service in the path — an S3 request resolves the caller's access key against this file and verifies SigV4 with the stored secret.

### How accounts are stored

versitygw owns the format: a `users.json` plus a `users.json.backup` it maintains itself, both `0600` root-owned.

```
/mnt/zfs/foundation/versitygw-iam/s3-hot/
├── users.json
└── users.json.backup
```

**Do not hand-edit these.** Use `versitygw admin create-user` / `update-user` / `delete-user`; the running gateway holds the file and writes it itself.

Both directories are on ZFS — including s3-bulk's, whose *objects* live on MergerFS+SnapRAID. SnapRAID parity is point-in-time, and losing the account store locks every consumer out of data that is otherwise intact. Both systemd units therefore `RequiresMountsFor` the IAM dir as well as the data dir: a gateway started onto an unmounted IAM dir would come up healthy with an empty account store and reject every non-root caller.

> **⚠️ IAM cache: account changes lag up to `--iam-cache-ttl` (default 120s).** After `create-user` / `update-user` / `delete-user`, S3 auth for that key may not reflect for up to 2 minutes. For immediate effect during ops, run with `--iam-cache-disable` or wait out the TTL. (A brand-new key that isn't cached yet resolves immediately on first use — the lag bites on *changes* to already-cached keys.)


## The admin API (user & bucket management)

`versitygw admin` is a client subcommand that talks to a running gateway's **admin port**. Auth is SigV4 with an admin/root credential.

```
versitygw admin -a <admin-access> -s <admin-secret> --er <admin-endpoint> <subcommand> [opts]
```

- Admin creds also read from env **`ADMIN_ACCESS_KEY_ID` / `ADMIN_SECRET_KEY`** — prefer these over `-a/-s` so secrets stay off argv.
- `--er, --endpoint-url` (env `ADMIN_ENDPOINT_URL`) points at the admin port, e.g. `http://versitygw:7071`.
- `--allow-insecure, --ai` skips TLS verification for the admin endpoint (if admin TLS is on).

| Subcommand | Purpose | Key flags |
|---|---|---|
| `create-user` | Create an account | `-a` access, `-s` secret, `-r` role, `--ui/--gi/--pi` user/group/project id |
| `update-user` | Change secret / ids of an account | `-a` access, `-s`, `--ui/--gi/--pi` |
| `delete-user` | Remove an account | `-a` access |
| `list-users` | List accounts (from the IAM backend) | — |
| `create-bucket` | Create a bucket owned by a user | `--owner <access>`, `--bucket <name>` |
| `list-buckets` | List buckets + owners | — |
| `change-bucket-owner` | Reassign a bucket (drops its old ACL/policy) | `-b <bucket>`, `-o <new-owner-access>` |

**Roles** (the `-r` value): `user` (may only use buckets it's been granted — **cannot create buckets**), `userplus` (may create/own its own buckets), `admin` (full). In the spike, a `user`-role key got `AccessDenied` on `CreateBucket`; recreating it as `userplus` let it create and own buckets (on-disk `user.acl` then shows `Owner: appuser`).

```
# create a userplus account (writes to the file store):
ADMIN_ACCESS_KEY_ID=<root> ADMIN_SECRET_KEY=<root-secret> \
  versitygw admin --er http://versitygw:7071 create-user -a appuser -s <secret> -r userplus
versitygw admin --er http://versitygw:7071 list-users
```

## Client recipes (path-style; virtual-host is off unless `--virtual-domain` is set)

**aws-cli** — endpoint + creds via env, path-style is automatic:

```
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… AWS_DEFAULT_REGION=us-east-1 \
  aws --endpoint-url http://<host>:7070 s3 ls
# multipart is automatic above the 8 MiB default threshold and round-trips cleanly (verified 20 MiB)
```

**s3cmd** — force path-style by setting `--host-bucket` to the host without a bucket placeholder:

```
s3cmd --no-ssl --host=<host>:7070 --host-bucket=<host>:7070 \
      --access_key=… --secret_key=… ls
```

**boto3** — `endpoint_url=http://<host>:7070`, `config=Config(s3={'addressing_style':'path'})`.

## Observability & ops quick-reference

- **Health:** `GET <s3-port>/health → 200` (enabled by `--health`). Container status via `docker ps` / k8s readiness probe.
- **Logs:** per-request lines on stdout (silence with `--quiet`); `--access-log <file>` for a dedicated access log; `--iam-debug` / `--debug` for auth/signing diagnosis; captured by the container runtime.
- **Metrics:** StatsD (`--mss`) / DogStatsD (`--mds`). No native Prometheus endpoint — bridge via a statsd-exporter if Prometheus scraping is wanted.
- **Events:** bucket notifications to Kafka / NATS / RabbitMQ / webhook (`--event-*`).
- **Restart/recovery:** stateless — `docker restart` (or pod reschedule) is safe and loses nothing; all state is the backend dir + the IAM dir. Any flag/config change *requires* a restart (no live reload).
- **Dependencies:** the backing filesystem (ZFS `s3-hot` / MergerFS+SnapRAID `s3-bulk`) must be mounted with working `user.*` xattr support before start (validated at startup), and the ZFS IAM dataset must be mounted. Nothing external.

## Gotchas (the short list)

1. **IAM account changes lag up to 120s** (`--iam-cache-ttl`). Use `--iam-cache-disable` for immediate effect.
2. **Never hand-edit `users.json`** — the running gateway owns the file. Go through `versitygw admin`.
3. **GOVERNANCE object-lock can't be bypassed in v1.6.0** — it behaves like COMPLIANCE (see caveat). Re-verify on version bumps.
4. **Role `user` cannot create buckets** — use `userplus` for self-service bucket owners.
5. **Bucket-name validation happens before signature verification** — an invalid bucket name masks auth errors; test auth against a valid bucket name.
6. **Config is 100% flags/env (stateless)** — there is no config store to edit and no reload; restart the process to change anything.
7. **`--disable-copy-file-range`** exists for NFS-backed roots that hang on multipart completion. Our roots are local, but the pool also serves NFS — remember this if the mount topology changes.
8. **Metadata needs xattrs.** On a filesystem without `user.*` xattr support, startup fails; fall back to `--sidecar <dir>` (never `--nometa`).
