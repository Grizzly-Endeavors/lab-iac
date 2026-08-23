# ADR-024: Platform Secrets on OpenBao (ESO for Kubernetes, AppRole for Ansible)

**Date:** 2026-04-17
**Status:** superseded by [ADR-073](073-retire-openbao.md) (OpenBao retired; 1Password is the secrets source of truth)

## Context

ADR-023 stood up self-hosted OpenBao on r730xd as the self-hosted environment's secrets-of-truth and explicitly deferred consumer migration to follow-up work. This ADR executes that follow-up: move the 19 platform-level `vault_*` entries (DNS token, iDRAC, foundation stores, observability, CI/CD, GitHub App) out of Ansible Vault and into OpenBao, with Ansible reading back via AppRole and Kubernetes workloads reading back via a cluster-scoped ExternalSecret contract. App-level secrets (Gemini, Cerebras, per-app Postgres users) remain in Ansible Vault for a future pass.

The platform is only usable for reads once three pieces land together: the audit device must be enabled (ADR-023 called this a HIGH-severity blocker and it was unresolved at initial deploy), an auth method per consumer must exist, and consumers must have a path to authenticate that doesn't reintroduce the same "plaintext shared secret everywhere" problem OpenBao was supposed to fix.

## Decision

**External Secrets Operator (ESO) for Kubernetes consumers via the Kubernetes auth method. AppRole (CIDR-bound to 10.0.0.0/24, LAN-only) for Ansible consumers. Audit enabled declaratively in `openbao.hcl` before any secret is seeded.**

Specifically:

1. **Audit device first.** Declarative `audit "file" "main"` block in the role template, writing to the ZFS hot tier. OpenBao 2.5.2 ships the fix for openbao/openbao#2168 so stanzas no longer need a SIGHUP after boot. Two-tier Prometheus alerts (`OpenbaoAuditLogDiskFull` at 15% warn, `OpenbaoAuditLogDiskCritical` at 5% page).
2. **ESO, not VSO or CSI Driver.** ESO is vendor-neutral (also works with Infisical, AWS SM, etc. — future-proofs the self-hosted against OpenBao-specific lock-in), has a simpler CRD surface (ExternalSecret vs VaultStaticSecret + VaultDynamicSecret + VaultPKISecret…), and is the more commonly-deployed pattern in CNCF-native clusters. Loss: VSO's in-pod hot-reload of secret files; ESO materializes into a K8s Secret and the consumer restarts on change (Reloader can automate this if/when needed). Not adopting the Secrets Store CSI Driver because it adds a per-pod sidecar and another layer of syncing, with no benefit for self-hosted workloads that are already fine with K8s-Secret semantics.
3. **AppRole for Ansible, not static token.** Token helps rotate without editing vault.yml every time; role_id + secret_id live in vault.yml, but `rotate-openbao-keys.yml --tags approle-secret` mints a fresh secret_id on demand. Role is CIDR-bound to `10.0.0.0/24` on both token and secret_id, so a leak off-LAN is unusable. Token TTL 1h / max 4h — if a rendered token does leak, the window is small.
4. **Dedicated `openbao-auth` ServiceAccount in `external-secrets` ns, bound to `system:auth-delegator`.** This is the reviewer identity OpenBao presents to the cluster's TokenReview API when validating incoming SA tokens from ESO. Uses the K8s 1.24+ pattern of an explicit `kubernetes.io/service-account-token`-typed Secret to get a long-lived reviewer JWT (K8s no longer auto-generates these). Rotation via `rotate-openbao-keys.yml --tags k8s-auth-jwt` — delete the Secret, kubectl re-applies, OpenBao reconfigures.
5. **CA bundle committed to git at `kubernetes/infrastructure/external-secrets/openbao-ca-configmap.yaml`.** The CA is self-signed but public-safe (it's an issuer anchor, not a signing key). One ConfigMap in `external-secrets` ns, referenced by the ClusterSecretStore's `caProvider`. Rotation: `scripts/fetch-openbao-ca.sh` pulls the current cert off r730xd and embeds it in the ConfigMap; Flux reconciles. Avoids per-namespace ConfigMaps (drift) and baking the CA into the HelmRelease (harder to rotate).
6. **WireGuard keys stay in vault.yml.** The `ingress-tunnel` role template references `vault_wg_*_private_key` directly (bypassing the `vars.yml` indirection), so migrating means rewriting that role — disproportionate to the value. Rotation cadence is effectively never, so high-churn secret management adds nothing. Annotated in vault.yml explaining why.
7. **Infisical bootstrap creds stay in vault.yml.** Bootstrap chicken-and-egg: OpenBao's unseal path *needs* Infisical, Infisical needs `vault_infisical_openbao_client_id/_secret`. Putting them in OpenBao breaks cold-boot. Not movable; keeps vault.yml non-empty even post-migration.
8. **Per-playbook feature flag `openbao_read_enabled` (default false).** Opt-in via `include_vars` of `ansible/vars/openbao_secrets.yml` only when the flag is true. Lookups in `vars.yml` are rejected because they would fire at var-access time for *every* play, hard-coupling unrelated playbooks (r730xd-zfs, setup-claude-user) to OpenBao availability. Feature flag gives a clean rollback knob and a phased per-playbook rollout.

## Alternatives Considered

- **Vault Secrets Operator (HashiCorp).** Rejected for ecosystem neutrality — tighter Vault/OpenBao integration (dynamic creds, PKI, transit resource types) isn't worth the vendor-lock and larger CRD surface for a self-hosted where a flat KV store covers everything in scope. Reconsider if/when the self-hosted needs Vault-specific primitives like dynamic Postgres credentials issued per-pod.
- **Secrets Store CSI Driver.** Rejected because it adds a per-pod sidecar + a per-pod volume mount with its own syncing loop, for no benefit over ESO's "materialize to K8s Secret" contract in workloads that are already Secret-native.
- **Static long-lived token for Ansible.** Rejected because rotation requires editing vault.yml every time, creating a higher-friction rotation pattern than AppRole. AppRole's role_id + secret_id are also in vault.yml, but `rotate-openbao-keys.yml --tags approle-secret` rotates without touching vault.yml manually.
- **Response-wrapped secret_id stored in vault.yml.** Rejected because wrap tokens are single-use-and-expiring — one playbook run would consume the token, the next would fail. Wrap semantics are a delivery pattern, not a long-lived storage pattern.
- **Kubernetes auth for Ansible too.** Rejected because the controller (jumpbox / bear-desktop) isn't a K8s pod; no SA JWT to present.
- **Per-namespace CA ConfigMap / per-HelmRelease CA bundle.** Rejected — drifts when rotated, multiplies points of change. Single ConfigMap in `external-secrets` ns with `caProvider` on the ClusterSecretStore.
- **Migrate WireGuard keys anyway.** Rejected because the `ingress-tunnel` role template references `vault_wg_*_private_key` directly (not through the `vars.yml` indirection), so the migration would require rewriting that role's templating. The keys rotate on a "never unless compromised" cadence — migration adds complexity for no practical rotation benefit.
- **Use `bao audit enable` API instead of declarative HCL.** Rejected because OpenBao 2.5 returns 400 on the API path; the intended mechanism is the declarative `audit "<type>" "<path>" { options { ... } }` block in `openbao.hcl`. The 2.5.0-beta had a bug where stanzas were ignored at boot (openbao/openbao#2168) — fixed in PR #2170, backported to release/2.5.x on 2025-11-28, shipped in v2.5.2.

## Consequences

- **Single secret path layout for the self-hosted environment.** Every platform secret lives under `secret/grizzly-platform/<domain>/<name>` (KV v2). Adding a new secret is one `bao kv put` + one lookup entry in `openbao_secrets.yml` + (if K8s-consumed) one `ExternalSecret` manifest. Future-self looking for "where does secret X live?" has one place to look — path layout in `docs/runbooks/openbao-quickref.md`.
- **Ansible Vault shrinks but doesn't disappear.** Post-migration, vault.yml holds: Infisical bootstrap pair, AppRole pair, WireGuard privates, app-level secrets. From ~36 entries down to ~10. Still encrypted, still version-controlled, still uses `.vault_pass` — just smaller and more clearly scoped to "things OpenBao can't hold."
- **Cold-boot path unchanged.** r730xd boots → systemd auto-unseal fetches keys from Infisical using the creds in vault.yml → OpenBao unseals → Ansible playbooks that need platform secrets can now reach OpenBao via AppRole. The only new runtime dependency is "Ansible controller can reach `https://10.0.0.200:8200`" — already true for every existing playbook that talks to r730xd.
- **ESO becomes a tier-1 cluster dependency.** If the ESO controller is unhealthy, `github-app-credentials` stops refreshing. Within a ~1h `refreshInterval` window nothing breaks (the Secret persists), but beyond that the risk is drift during rotation. Mitigated by: (a) ESO runs HA-by-default in the chart; (b) `rollback-openbao-migration.yml` can re-seed imperatively in minutes; (c) Flux will reconcile the HelmRelease if the pods fail.
- **Two rotation playbooks instead of N ad-hoc secret management scripts.** `rotate-openbao-keys.yml` covers unseal keys, root token, Infisical identity, AppRole secret_id, and K8s reviewer JWT. Platform-secret rotation is `bao kv put`. Application-secret rotation happens at the app source + `bao kv put` + `kubectl annotate externalsecret ... force-sync`.
- **Stale `ansible/group_vars/all/` directory must be cleaned up.** The repo has two `group_vars/all/` trees — the authoritative one at `ansible/inventory/group_vars/all/` (referenced in `ansible.cfg`) and a stale duplicate at `ansible/group_vars/all/`. The duplicate has already drifted and is a silent-regression risk during the Phase E vault.yml shrink. Delete it as part of post-migration cleanup.
- **No VSO means no dynamic DB creds path for now.** If future apps want per-pod Postgres/MySQL credentials issued by Vault, we either add VSO alongside ESO or adopt OpenBao's database secrets engine and route through ESO's dynamic secrets support (ESO 0.9+ supports some Vault dynamic providers but the story is less complete than VSO's). Reconsider in a future ADR.

## References

- `ansible/roles/r730xd-openbao/templates/openbao.hcl.j2` — audit device block.
- `ansible/playbooks/bootstrap-openbao.yml` — AppRole + new policies.
- `ansible/playbooks/setup-openbao-k8s-auth.yml` — Kubernetes auth wiring.
- `ansible/playbooks/migrate-platform-secrets-to-openbao.yml` — one-shot seed.
- `ansible/playbooks/rotate-openbao-keys.yml` — extended with `approle-secret` and `k8s-auth-jwt` flows.
- `ansible/playbooks/rollback-openbao-migration.yml` — back out of migration safely.
- `ansible/vars/openbao_auth.yml`, `ansible/vars/openbao_secrets.yml` — Ansible consumer-side wiring.
- `scripts/set-openbao-approle-secrets.sh`, `scripts/fetch-openbao-ca.sh` — helper scripts.
- `kubernetes/infrastructure/external-secrets/` — ESO + ClusterSecretStore + reviewer-JWT SA.
- `docs/runbooks/secrets-migration.md` — operator guide for Phase A–E.
- `docs/runbooks/openbao-quickref.md` — updated with policies, auth methods, path layout, rotate/add how-tos.
- ADR-023 (self-hosted OpenBao on r730xd) — prerequisite; this ADR is the deferred consumer migration.
- ADR-019 (ingress + TLS termination) — why WireGuard keys are exempt (ingress-tunnel role references vault_* directly).
- openbao/openbao#2168, PR #2170 — audit-device-at-boot bug + fix backported to 2.5.2.
