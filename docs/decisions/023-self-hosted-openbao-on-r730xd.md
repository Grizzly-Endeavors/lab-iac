# ADR-023: Self-Hosted OpenBao on R730xd

**Date:** 2026-04-17
**Status:** superseded by [ADR-073](073-retire-openbao.md) (OpenBao retired; 1Password is the secrets source of truth)

## Context

Secret management across the self-hosted has drifted into several uncoordinated stores:

- **Ansible Vault** (`group_vars/all/vault.yml`) holds ~15 secrets consumed by IaC playbooks and is seeded into Kubernetes via imperative `kubectl apply` calls from `seed-app-secrets.yml`.
- **Infisical** is used for OIDC in some GitHub Actions workflows (`family-dashboard`, `game-server-platform`) but is not integrated with anything in-cluster.
- **GitHub Secrets** are the direct source for other workflows (`coaching-website`, `relay`).
- Several project repos commit `.env` files containing real API keys (`residuum/.env`, `lab-logger/.env`, `comcast-issues-logger/.env`).

The cost of this sprawl is operational: adding a new secret requires touching 2–3 different systems; rotating a secret means chasing down every consumer manually; and the repo-committed keys are a latent exposure. A single source of truth is needed.

The self-hosted has the key constraint that **k8s is not a safe place to put bootstrap secrets**: kubeadm/Flux/ARC/secrets seeding all depend on credentials that must exist before the cluster is healthy, and the cluster depends on R730xd's foundation stores for persistence. Anything that lives in k8s cannot be trusted to be available when the cluster is being rebuilt.

## Decision

**Self-host OpenBao on R730xd, with integrated Raft storage, as the self-hosted secrets single source of truth.**

Specifically:

1. **OpenBao, not HashiCorp Vault.** OpenBao is the Linux Foundation fork under MPL-2.0; Vault's BSL change makes it unsuitable for long-lived self-hosted deployments where licensing clarity matters more than feature lead time. OpenBao tracks Vault's APIs and CLI surface.
2. **Integrated Raft storage, not Postgres.** R730xd already runs Postgres as a foundation store, but using it as OpenBao's backend would create a runtime dependency where OpenBao depends on Postgres — and any future app whose Postgres credentials live in OpenBao would then have a circular dependency at boot. Raft eliminates this by keeping OpenBao self-contained: its data lives on ZFS at `/mnt/zfs/foundation/openbao/data` and its only runtime dependency is Docker.
3. **Scripted unseal via Infisical bootstrap secrets.** OpenBao is sealed at every boot (Shamir 5-of-3). The 5 unseal shares and the root token are stored in Infisical's free tier; on each boot a systemd oneshot (`openbao-auto-unseal.service`) fetches the threshold number of shares via the Infisical CLI using a universal-auth machine identity, and submits them to `bao operator unseal`. Only the universal-auth `client_id`/`client_secret` pair (in `group_vars/all/vault.yml`) and the CA bundle live outside OpenBao.
4. **Self-signed TLS issued by Ansible.** The `r730xd-openbao` role generates a fresh CA + leaf cert at install time and installs the CA into the host's system trust store (`/usr/local/share/ca-certificates/grizzly-platform-openbao-ca.crt`). SAN covers `r730xd`, `r730xd.lab`, `localhost`, `10.0.0.200`, `127.0.0.1`.
5. **LAN-only listener on `10.0.0.200:8200`.** No public exposure, no NetBird advertisement, no VPS tunnel route. Consumers are the jumpbox, K8s nodes, the R730xd itself (for backup cron), and the GitHub Actions runner on `deb-web` — all on the LAN.
6. **Migration is phased and out of scope for this ADR.** Day one stands up OpenBao with auto-unseal, bootstrap + rotation playbooks, monitoring, and backup. Existing Ansible Vault contents, in-cluster secrets, and GitHub Actions consumers migrate in follow-up work once the platform has proven stable.

## Alternatives Considered

- **Infisical-only.** Use Infisical for all self-hosted secrets, no self-hosted vault. **Rejected** because Infisical's free tier does not support the full API surface needed (e.g., dynamic database credentials, PKI issuing, per-path ACLs), and making every self-hosted service reach out to a SaaS for every reconnect couples the self-hosted environment's availability to the internet. Infisical stays — but as a tightly-scoped bootstrap store only.
- **HashiCorp Vault (BSL).** Rejected on licensing grounds. BSL is a moving target and this is a long-lived personal infrastructure project; there is no value in carrying that compliance burden when OpenBao is API-compatible.
- **Postgres backend for OpenBao.** Rejected because it creates the exact circular dependency the foundation-store model is designed to avoid: Postgres credentials belong in OpenBao, so OpenBao cannot depend on Postgres being up.
- **OpenBao on Kubernetes (Helm chart).** Rejected because the cluster depends on secrets that would then live in the cluster. The cluster would not be able to cold-boot from scratch without some other bootstrap path, which defeats the purpose.
- **Cloud KMS auto-unseal (AWS/GCP/Azure).** Rejected because it adds a cloud dependency and a paid service for a feature Infisical's free tier can provide with one fewer moving part. Also, no existing self-hosted dependency on any of the three cloud KMSes.
- **Transit auto-unseal via a second OpenBao.** Rejected because a second OpenBao instance still needs *its* own seal keys managed somewhere, which just pushes the problem down a level. A single instance with scripted unseal is architecturally simpler and the self-hosted environment's availability target does not require HA.
- **Keeping Ansible Vault as the source of truth.** Rejected because Ansible Vault is file-based — no audit log, no fine-grained ACLs, no dynamic secrets, no revocation, no in-cluster injection path. It has served fine for IaC bootstrap but does not scale to "every secret, every consumer."

## Consequences

- **Three on-disk secrets on R730xd:** (1) `/etc/openbao/infisical-auth.env` (universal-auth client_id/secret), (2) `/etc/openbao/tls/server.key` (listener TLS private key), (3) the Raft data dir under `/mnt/zfs/foundation/openbao/data` (OpenBao's full state, encrypted at rest by OpenBao's own seal wrap). Compromise of #1 grants access to unseal keys in Infisical; compromise of #2 allows MITM of LAN traffic to OpenBao; compromise of #3 is useless without the seal key in memory.
- **Infisical is a single point of failure for seal recovery.** If the Infisical project is deleted or access is lost AND R730xd reboots, the only way to unseal is the unseal keys backed up out-of-band (password manager). The bootstrap playbook explicitly reminds the operator to create this second copy.
- **Ansible Vault stays small but still exists.** It keeps the Infisical bootstrap client_id/secret (because this is what we need to get anything out of OpenBao in a DR) and nothing else once migration is done. Size goes from ~15 vars to ~2.
- **Audit log on ZFS fills up if not rotated.** The role installs a logrotate config that copy-truncates `/mnt/zfs/foundation/openbao/audit/audit.log` daily and SIGHUPs the container to re-open. If rotation breaks, audit writes will eventually fail and OpenBao will start rejecting requests — the `OpenbaoAuditLogDiskFull` Prometheus alert fires at 15% free on the `/mnt/zfs` tier. At initial rollout on 2026-04-17 the audit device was not yet enabled — OpenBao 2.5 requires declarative HCL config for audit (the API-based `bao audit enable` path returned 400) and the correct block signature wasn't pinned down in time. It shipped shortly after as the declarative `audit "file" "main"` block in `openbao.hcl.j2`; see the "gotchas" section of `docs/runbooks/openbao-quickref.md`.
- **Scripted unseal at boot adds ~10 seconds to R730xd's ready state.** The `openbao-auto-unseal.service` is `After=foundation-openbao.service network-online.target`, so it only runs once the container is up and the Infisical CLI can reach the internet. In the worst case (Infisical unreachable) the unit fails and `OpenbaoUnavailable` + `OpenbaoAutoUnsealFailed` alerts fire, leaving the operator to unseal by hand from their password-manager copy.
- **No HA.** Single-node Raft. Losing R730xd means losing OpenBao until R730xd is rebuilt. Recovery path is: reinstall base OS → `ansible-playbook deploy-openbao.yml` → restore `bao operator raft snapshot restore <snapshot>` from the most recent ZFS snapshot of the foundation tier. Acceptable because the self-hosted has no HA target and every other foundation store has the same "R730xd-loss = downtime" property.
- **Self-signed TLS forces every consumer to import the CA bundle.** The role puts the CA into the host system trust store, and the K8s DaemonSet pattern (or a ConfigMap) will be how in-cluster consumers get it during the migration phase. The trade-off vs a Caddy-fronted Let's Encrypt cert is that self-signed has zero external dependencies and rotates on a 10-year cadence rather than 90 days — appropriate for a LAN-internal control plane.
- **Rotation is explicit and playbook-driven.** `ansible/playbooks/rotate-openbao-keys.yml` has three flows (`--tags rekey`, `--tags root-token`, `--tags infisical-identity`). There is no automatic rotation schedule; the operator runs rotation on a human cadence (quarterly recommended, see the rotation runbook).

## Deploy-time notes (2026-04-17)

Worth calling out from the initial rollout — details in `docs/runbooks/openbao-quickref.md` under "Gotchas":

- OpenBao 2.5 dropped mlock; `disable_mlock` in HCL is a hard error and `IPC_LOCK` is no longer required.
- The container's default entrypoint chowns `/openbao/config` at startup, which fights a read-only mount of root-owned files. The compose file bypasses the wrapper: `user: "0:0"` + `entrypoint: ["/bin/bao"]`.
- A self-signed CA needs to be driven through a CSR with `basic_constraints: CA:TRUE`; otherwise curl/openssl reject it as an invalid CA.
- `bao status` exits 2 when sealed or uninitialized, which breaks `set -o pipefail` scripts that pipe through grep. The auto-unseal script captures output with `|| true` before inspecting.
- Infisical `secrets set` defaults to `--type=personal`, which is per-user and invisible to the universal-auth identity on r730xd. All push calls pass `--type=shared`.
- The declarative audit device HCL schema for OpenBao 2.5 wasn't resolved during rollout — it shipped shortly after; see the Consequences section above.

## References

- `ansible/roles/r730xd-openbao/` — the role.
- `ansible/playbooks/deploy-openbao.yml` — deploys the role with pre-flight verification.
- `ansible/playbooks/bootstrap-openbao.yml` — one-time init; pushes keys to Infisical.
- `ansible/playbooks/rotate-openbao-keys.yml` — rekey / root-token / infisical-identity rotation.
- `scripts/set-openbao-bootstrap-secrets.sh` — idempotent upsert of the bootstrap creds into the Ansible vault.
- `docs/runbooks/openbao-quickref.md` — start here for "where/how do I…?" questions.
- `docs/runbooks/openbao-rotation.md` — cadence + step-by-step rotation guide.
- `docs/runbooks/openbao-disaster-recovery.md` — lost Infisical access, Raft corruption, R730xd rebuild.
- ADR-003 (foundation stores on R730xd) — explains why stateful workloads live here.
- ADR-019 (ingress + TLS) — establishes the "no public exposure for sensitive LAN services" posture that OpenBao inherits.
