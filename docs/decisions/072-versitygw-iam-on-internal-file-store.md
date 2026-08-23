# 072: versitygw Keeps Its S3 Accounts in Its Own File Store

**Date:** 2026-08-23
**Status:** accepted
**Related:** [ADR-055](055-s3-object-store-versitygw.md) (versitygw as the S3 object store), [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores on the R730xd), [ADR-073](073-retire-openbao.md) (retiring OpenBao)

## Context

Both S3 gateways stored their IAM *account records* — access key, secret key, role, and the numeric uid/gid/project ids — in an OpenBao KV-v2 mount, reached with a shared AppRole. This was the last load-bearing use of OpenBao on the platform: secret *delivery* had already moved to 1Password, but the S3 account store had not, so OpenBao could not be switched off without taking out every S3 account on both gateways.

The property that matters here is easy to misread. versitygw's IAM backend is not an identity source it consults; it is the gateway's own account *database*. It creates, modifies and deletes entries there through its admin API, and it reads the S3 secret key back out in cleartext on every request to verify the SigV4 signature. Whatever holds this data must accept writes from versitygw and hand back secrets in the clear.

versitygw offers five backends: an internal file store, LDAP, Vault/OpenBao, S3, and FreeIPA.

## Decision

Use the internal file store (`--iam-dir`), one directory per gateway, on a dedicated ZFS dataset at `tank/foundation/versitygw-iam/{s3-hot,s3-bulk}`. versitygw owns the on-disk format — a `users.json` plus a `users.json.backup` it maintains itself — and every account continues to be managed through the same admin API as before.

The dataset is ZFS for **both** gateways, including the bulk tier whose objects live on MergerFS+SnapRAID. SnapRAID parity is point-in-time, and an account store is not an object: losing it locks every S3 consumer out of a pool whose data is still perfectly intact. ZFS gives it real-time raidz1 redundancy and puts it under the existing pool snapshots and scrub.

Because the account store now sits on a different filesystem than the bulk tier's objects, both systemd units guard on both mounts (`RequiresMountsFor`). A gateway started onto an unmounted IAM directory would otherwise come up healthy with an empty account store and silently reject every non-root consumer.

## Alternatives Considered

- **LDAP against the existing Authentik instance** — The appealing option on paper: S3 accounts would live in the identity system that already owns platform identity. It cannot work. authentik's LDAP outpost registers exactly four handlers — bind, unbind, search, close (`internal/outpost/ldap/ldap.go`) — and implements no add, modify, or delete. versitygw's LDAP backend issues `ldap.NewAddRequest`/`Add` on `create-user`, `NewModifyRequest`/`Modify` on `update-user`, and `NewDelRequest`/`Del` on `delete-user` (`auth/iam_ldap.go`), so every account operation would fail against a read-only outpost. The second problem is independent of the first: versitygw writes the S3 secret as a plain directory attribute and reads it back to verify signatures, and Authentik has nowhere appropriate to hold a cleartext service credential. These are S3 service accounts, not people — the "accounts live in the identity system" benefit does not really exist.
- **A writable LDAP directory of our own (lldap or OpenLDAP)** — Technically works, and would satisfy the letter of "use LDAP." Rejected because it trades OpenBao for a different always-on daemon in front of S3 authentication, one that must be secured, backed up, monitored and alerted on, and that holds S3 secrets in cleartext regardless. The dependency is the cost being eliminated; swapping which daemon holds it is not progress.
- **Keeping OpenBao solely for versitygw IAM** — Running an entire secrets server, with its unseal ceremony, auto-unseal key custody, TLS CA, agent, and alerting, to hold nine small account records. This is the cost [ADR-073](073-retire-openbao.md) exists to remove.
- **The S3 IAM backend** — Stores the account file in an S3 bucket, which is circular for a gateway that *is* the S3 provider: each gateway's authentication would depend on the other one being up.

## Consequences

- **S3 authentication has no external dependency.** The gateways depend on their backing filesystems and nothing else. Previously an OpenBao outage, a sealed vault, an expired AppRole secret_id, or a rotated CA could break S3 auth platform-wide; none of those failure modes exist now.
- **OpenBao becomes decommissionable.** This was the last thing holding it up.
- **The account store is a file, so it is only as available as the host.** There is no replication and no HA story — acceptable because versitygw is a single-host service on the R730xd anyway, and the gateway processes themselves are already a single point of failure for their tier. ZFS covers disk failure; host loss is a restore.
- **Account changes still lag up to `--iam-cache-ttl` (120s).** Unchanged from the OpenBao backend — the cache sits in front of whichever store is configured.
- **Nine accounts migrated with their credentials preserved byte-for-byte,** so no consumer secret in 1Password changed and nothing downstream needed resyncing. `scripts/migrate-versitygw-iam-to-file.sh` performed the copy through the admin API and is retained as the record of how it was done.
- **A second mount guard now gates gateway startup.** Slightly more to go wrong at boot, deliberately: failing to start is much better than starting with an empty account store.
