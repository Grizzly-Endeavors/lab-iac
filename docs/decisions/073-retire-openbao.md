# 073: Retire OpenBao; 1Password Is the Secrets Source of Truth

**Date:** 2026-08-23
**Status:** accepted
**Supersedes:** [ADR-023](023-self-hosted-openbao-on-r730xd.md) (self-hosted OpenBao on the R730xd), [ADR-024](024-platform-secrets-on-openbao.md) (platform secrets on OpenBao), [ADR-035](035-internal-tls-openbao-pki.md) (internal TLS via OpenBao PKI — never implemented)
**Related:** [ADR-072](072-versitygw-iam-on-internal-file-store.md) (versitygw IAM on its own file store)

## Context

OpenBao was the platform's secrets source of truth: an ESO `ClusterSecretStore` for Kubernetes, an AppRole for Ansible, a KV mount for versitygw's S3 accounts.

What it cost to keep running was out of proportion to a single-operator homelab. A sealed vault after a power cut takes the whole platform's secret delivery down, so the unseal had to be automated, which meant the unseal keys and root token had to live somewhere *else* — a separate Infisical project, a second SaaS dependency existing only to start the first one. Around that: a self-signed CA whose certificate had to be fetched into a ConfigMap for ESO, installed in the controller's trust store, and inlined as PEM content into versitygw's config; an auto-unseal systemd unit; an agent process whose only job was minting a token so Prometheus could scrape the vault; an audit device that bricks the server if its disk fills; AppRole secret_ids with CIDR bindings; a Kubernetes auth method with a reviewer-JWT service account; and four runbooks (quickref, add-secret, rotation, disaster-recovery) to operate it.

None of that is unreasonable for what OpenBao is. It is unreasonable for what this platform asked of it, which was: store about forty credentials and hand them to ESO and Ansible.

## Decision

**Retire OpenBao outright and make the `grizzly-platform` 1Password vault the sole secrets source of truth.** Not a partial retirement keeping OpenBao for the Ansible path or other non-ESO consumers — the whole thing goes.

Three service account tokens reach the vault and nothing else does: `eso-reader` (ESO's `ClusterSecretStore`), `ansible-reader` (the `op` lookups in `ansible/vars/onepassword_secrets.yml`), and `operator` (the only one with `write_items`, for adding and rotating secrets by hand).

Items are named one per domain, `<domain>-<name>`, with field labels unchanged. The field is part of the ESO key rather than a separate property: `remoteRef.key: stores-postgres/password`.

The last load-bearing consumer, versitygw's S3 account store, moved to versitygw's own file store first ([ADR-072](072-versitygw-iam-on-internal-file-store.md)). That was the actual blocker — the `stores-versitygw-iam` item in 1Password held only the AppRole credential the gateways *authenticated with*, not the account data it unlocked.

Infisical goes too. It existed solely to hold OpenBao's unseal keys, and there is nothing left to unseal.

## Alternatives Considered

- **Keep OpenBao, move only ESO to 1Password.** The tempting middle ground, and the one this migration explicitly rejected. It keeps every operational cost above — the unseal ceremony, the Infisical dependency, the CA, the audit device, the four runbooks — while adding a *second* secrets system to keep in sync. Two sources of truth is worse than either one alone.
- **A different self-hosted secrets manager** (Vault proper, Infisical self-hosted, sops+age). Each solves the "don't depend on a SaaS" objection, and each brings back some version of the same operational surface. sops+age is the genuinely lighter option, but it puts encrypted secrets in git and makes rotation a commit — worse for a public repo, and it has no answer for ESO.
- **Cloud KMS-backed auto-unseal instead of the Infisical bootstrap.** Fixes the specific ugliness of the unseal-key custody without touching anything else on the list. A real improvement to a system we no longer want.

## Consequences

- **One secrets system, and it is one the operator already uses.** Recovery is an Emergency Kit rather than three-of-five Shamir shares held in a second SaaS.
- **`.vault_pass` is now the single recovery secret.** Every token is derivable from the encrypted `vault.yml` via `scripts/derive-op-tokens.sh`. A service account token cannot be read back out of 1Password once minted, so losing `.vault_pass` means re-minting every token by hand. It belongs in the operator's *human* 1Password account, which is recoverable via the Emergency Kit.
- **A hard 90-day expiry on every token, and a shared rate limit.** 1Password caps service account lifetime at 90 days and meters 1,000 requests per *account* per day across all tokens. Both are new failure modes that did not exist with a self-hosted vault. Mitigated by `OnePasswordTokenNearingMaxAge` (76 days), `ClusterSecretStoreNotReady` from daily store validation, and `OnePasswordApiVolumeHigh`; and by ExternalSecrets syncing `OnChange` rather than polling.
- **Secret delivery now depends on a third party being reachable.** A 1Password outage breaks the next rotation and any new sync, but not running workloads — materialised Secrets keep serving. This is a real reduction in autonomy, accepted because a sealed OpenBao after a power cut was a more frequent and more total outage in practice.
- **No internal CA.** [ADR-035](035-internal-tls-openbao-pki.md) proposed OpenBao PKI as the internal trust root; it was never implemented (the cluster has only the Let's Encrypt and self-signed issuers). Retiring OpenBao forecloses that specific path. If an internal CA is wanted later it will be a cert-manager-managed one, and that gets its own ADR.
- **Four runbooks retire with the server** (`openbao-quickref`, `openbao-add-secret`, `openbao-rotation`, `openbao-disaster-recovery`), replaced by the single [onepassword-quickref.md](../runbooks/onepassword-quickref.md).
