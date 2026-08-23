# Stalwart CLI — Operating Reference

How to drive the Stalwart 0.16 mail server's config from the control node with the first-party CLI (`stalwartlabs/cli`). Stalwart 0.16 is **database-backed**: the static `config.json` holds only the data-store object; everything else (blob store, listeners, TLS, domains, accounts, DKIM, security, outbound routing) lives in Postgres and is managed through this schema-driven, kubectl-style CLI. This page is the "how to drive the tool" reference; the mail **deployment** story, gotchas, and resume state live in [`mail.md`](mail.md).

> **Keep this current.** This runbook exists so sessions stop reverse-engineering the CLI. Whenever you learn a new surface (a verb flag, a field shape, an object quirk, a working recipe) or find something here has gone stale (CLI/server version bump changes behaviour, an object is renamed, a documented shape stops validating), **update this file in the same change** — add the recipe, correct the drift, bump the version note. A wrong entry here is worse than a missing one: it sends the next session down a false path. When in doubt, re-verify against `stw describe` / `--help` and record what you found.

## Invocation

The CLI runs as a container and authenticates as the deterministic recovery admin (1Password item `platform-stalwart`, field `admin_password`). From the control node:

```
export OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/op-tokens/operator)"
ADMIN_PW=$(op read op://grizzly-platform/platform-stalwart/admin_password)

stw(){ docker run --rm \
  -e STALWART_URL=https://mail.grizzly-endeavors.com -e STALWART_USER=admin -e STALWART_PASSWORD="$ADMIN_PW" \
  ghcr.io/stalwartlabs/cli:1.0.10 -k "$@"; }

stw describe                       # list every object type
stw query Account --json           # etc.
```

Notes:
- **Password is passed via `-e STALWART_PASSWORD` (inherited env), never on the command line** — keep it that way (and `no_log: true` in Ansible).
- `-k` skips TLS verification. The prod cert *is* valid, but `-k` avoids trusting the LE chain inside the throwaway container and is what the playbook uses — keep it consistent.
- **Pin the CLI image to match the deployed server's schema.** Currently `cli:1.0.10` against server `stalwart:v0.16.11`. Bump both together; verify the current CLI tag on the `stalwartlabs/cli` GHCR before changing.
- `--debug` prints the underlying HTTP request/response — reach for it when a patch is rejected and the error is opaque.
- The CLI talks to the HTTP surface, which shares the ingress-nginx IP. If the auto-ban has wedged the ingress (502 everywhere), bypass it: `kubectl -n stalwart port-forward pod/<pod> 18080:8080` then point the CLI at `STALWART_URL=http://localhost:18080` with `--network host`. See the "ingress-ban trap" in [`mail.md`](mail.md).

## The verbs

| Verb | Purpose | Key flags |
|---|---|---|
| `describe [NAME]` | Schema introspection. Omit NAME to **list all objects**; give a name for fields/types/variants. | — |
| `query <Object>` | List objects, **summary fields only**. | `--where field=val` (repeatable; `= >= <= > <`), `--fields a,b`, `--json` |
| `get <Object> [ID]` | Fetch **one full object** (all fields). Omit ID for singletons (or literal `singleton`). | `--fields`, `--json` |
| `create <Object>[/Variant]` | Create an object; `/Variant` picks a variant (e.g. `Account/User`). | `--json '{...}'`, `--field k=v` (repeatable), `--file`, `--stdin` |
| `update <Object> [ID]` | Patch by id (omit ID / `singleton` for singletons). | `--field 'ptr=val'` (JSON pointer paths), `--json`, `--file`, `--stdin` |
| `delete <Object>` | Delete by id(s). | `--ids id1,id2`, `--stdin` |
| `apply` | Bulk plan (create/update/upsert/destroy) from JSON. This is the **declarative path**. | `--file`, `--stdin`, `--dry-run`, `--continue-on-error`, `--json` (NDJSON) |
| `snapshot <Object>...` | Export live objects into an `apply`-consumable plan file — **backup / diff**. | `--output PATH`, `--include-secrets` (default strips secrets), `--allow-unresolved` |

## Schema model — read this before patching

- **Discover, don't guess.** `stw describe <Object>` prints every field with its type, mutability (`mutable` / `server-set`), and (for multi-variant objects) the variants. This is how you learn the exact shape instead of reverse-engineering it. `stw describe <Enum>` works too.
- **Singletons vs id'd objects.** `describe` marks singletons `[singleton]` (e.g. `SystemSettings`, `BlobStore`, `Security`, `MtaOutboundStrategy`). Update them with no id: `stw update SystemSettings --json '{...}'`. Everything else (Account, Domain, Certificate, NetworkListener, DkimSignature, MtaRoute, AllowedIp, BlockedIp, …) is id-addressed.
- **`query` returns a summary; `get` returns everything.** `query Account --where name=bearflinn --json` gives `{id, emailAddress, ...}` (a few fields). To see the whole object (e.g. the `aliases`/`credentials` maps) use `get Account <id> --json`.
- **Nested collections are index-keyed MAPS, not JSON arrays.** `credentials`, `aliases`, listener `bind`, `overrideProxyTrustedNetworks`, `subjectAlternativeNames`, `AllowedIp.address` sets — all render as `{"0": {...}, "1": {...}}` / `{"key": true}`. Patch them with JSON-pointer paths: `--field 'aliases/0={"name":"postmaster","domainId":"b"}'`. Passing a `[...]` array gets rejected with `Invalid value for object property`.
- **Typed secret / value objects.** Secret and text fields take a tagged object, NOT a bare string, and Stalwart 0.16 does **not** expand `%{env:}%` macros anywhere:
  - `{"@type":"EnvironmentVariable","variableName":"S3_SECRET_KEY"}` — read from pod env (used for blob-store `secretKey`, data-store `authSecret`; the Part-C SMTP2GO relay password will use this).
  - `{"@type":"File","filePath":"/etc/stalwart/tls/tls.key"}` — read from a mounted file (TLS cert/key).
  - `{"@type":"Value","secret":"..."}` / `{"@type":"Password","secret":"..."}` — literal (mailbox password, injected from 1Password by the playbook — never committed).
- **`@type` values are PascalCase** (`PostgreSql`, `S3`, `Password`). A store's endpoint region is `{"@type":"Custom","customEndpoint":"...","customRegion":"us-east-1"}`.
- **In-plan `#ref` resolution is unreliable for `id<...>` fields.** For cross-object references (e.g. `SystemSettings.defaultCertificateId`) the playbook queries the live id and sets it in a follow-up `update`, rather than referencing it inside the plan. Do the same.

## Recipes

**Inspect the schema of anything:**
```
stw describe                 # catalog
stw describe Account         # fields + variants (User/Group)
stw describe MtaRoute        # outbound routing shape (Part C)
```

**Accounts / aliases** (bootstrap mailbox is `Account/User`, id `b`, domain id `b`):
```
stw query Account --where name=bearflinn --json           # find id
stw get   Account b --json                                # full object
stw update Account b --field 'aliases/0={"name":"postmaster","domainId":"b"}' \
                     --field 'aliases/1={"name":"abuse","domainId":"b"}'
# set/rotate a password credential (prefer the playbook, which injects from 1Password):
stw update Account b --field 'credentials/0={"@type":"Password","secret":"<pw>"}'
```
`EmailAlias = {name: <local-part>, domainId}` — `name` is the **local part only** (a full `x@y` is rejected as "Invalid email local part"; `domainId` is required).

**Reloads / server actions** (`Action` is create-only — you *create* an action to run it):
```
stw create Action/ReloadSettings
stw create Action/ReloadTlsCertificates      # after a renewed cert file syncs
stw create Action/ReloadBlockedIps
```
Other variants: `ReloadLookupStores`, `UpdateApps`, `TroubleshootDmarc`, `ClassifySpam`. **Reloads do NOT rebuild the S3 blob client or re-bind listener sockets** — those need a pod restart (`kubectl -n stalwart rollout restart deploy/stalwart`). TLS cert reloads *do* take via the action.

**Auto-ban recovery** (an IP wedged by failed logins):
```
stw query BlockedIp --json
stw delete BlockedIp --ids <id>
```
Internal ranges are permanently exempt via an `AllowedIp` for `10.0.0.0/8` (in `plan.json`).

**Backup / diff the live config:**
```
stw snapshot Domain Account NetworkListener Certificate --output /tmp/stalwart-snapshot.json
# diff against the committed plan, or re-apply elsewhere:
stw apply --file /tmp/stalwart-snapshot.json --dry-run
```

## Declarative path (the source of truth)

Day-to-day config is **not** hand-typed — it lives in `ansible/files/stalwart/plan.json` (an `apply` plan of `upsert`/`update` ops keyed by `matchOn`) and is driven by `ansible/playbooks/configure-stalwart.yml`, which also does the pieces the plan can't express (SystemSettings id cross-refs, stdout tracer, the mailbox password + aliases). Re-apply (idempotent):
```
ansible-playbook ansible/playbooks/configure-stalwart.yml --vault-password-file .vault_pass
# blob-store / listener edits need the pod rebuilt:
ansible-playbook ansible/playbooks/configure-stalwart.yml --vault-password-file .vault_pass -e stalwart_force_restart=true
```
Prefer editing `plan.json` + the playbook over ad-hoc `update`/`create` so the change is reproducible; use the ad-hoc verbs for inspection, one-offs, and recovery.

## Object catalog (from `describe`, server 0.16.11)

Grouped for orientation — `[s]` = singleton. Full authoritative list is always `stw describe`.

- **Accounts/dir:** Account, AccountPassword[s], AccountSettings[s], Directory, Tenant, Role, ApiKey, AppPassword, OAuthClient, MaskedEmail, MailingList, PublicKey
- **Domains/DNS/TLS:** Domain, Certificate, AcmeProvider, DnsServer, DnsResolver[s], MtaSts[s]
- **Listeners/protocols:** NetworkListener, SystemSettings[s], Http[s], Imap[s], Jmap[s], WebDav[s], Application, HttpForm[s], HttpLookup
- **Inbound SMTP stages:** MtaStageConnect/Ehlo/Mail/Rcpt/Data/Auth[s], MtaInboundSession[s], MtaInboundThrottle, MtaExtensions[s], MtaHook, MtaMilter
- **Outbound (Part C lives here):** **MtaRoute**, **MtaOutboundStrategy[s]**, MtaConnectionStrategy, MtaTlsStrategy, MtaDeliverySchedule, MtaOutboundThrottle, MtaQueueQuota, MtaVirtualQueue, QueuedMessage
- **Auth results / reports:** SenderAuth[s], DkimSignature, DkimReportSettings[s], DmarcReportSettings[s], Dmarc{Internal,External}Report, Spf/Tls/DsnReportSettings[s], ReportSettings[s]
- **Storage:** BlobStore[s], DataStore[s], MetricsStore[s], SearchStore[s], TracingStore[s], InMemoryStore[s], FileStorage[s], StoreLookup, DataRetention[s]
- **Security/spam:** Security[s], AllowedIp, BlockedIp, Asn[s], Spam* (SpamSettings[s], SpamRule, SpamClassifier[s], SpamDnsblServer, …)
- **Ops:** Action, Alert, Metric(s), Tracer, EventTracingLevel, Task, TaskManager[s], Cache[s], WebHook, ClusterNode, ClusterRole, Coordinator[s]

### For Part C (outbound smarthost)
The relevant objects are **`MtaRoute`** (route/relay rule) and the **`MtaOutboundStrategy`** singleton (which route/schedule/TLS strategy the queue uses), with the SMTP2GO password supplied via an `{"@type":"EnvironmentVariable"}` secret. Start with `stw describe MtaRoute` and `stw describe MtaOutboundStrategy` to get exact field names before writing the plan — don't assume the shape.
