# Runbooks — index

One line per runbook. See [`README.md`](README.md) for what runbooks are and when to reach for one.

## Secrets

- [onepassword-quickref.md](onepassword-quickref.md) — the vault, the three service account tokens, rate limits, alert response, token rotation, and standing up a control node. **The secrets runbook.**

## Mail (Stalwart)

- [mail.md](mail.md) — deployment status, architecture, and operator runbook for the mail stack. **Start here for mail.**
- [stalwart-cli.md](stalwart-cli.md) — driving Stalwart's schema-driven config CLI (verbs, object model, recipes).

## Storage

- [zfs-pool-maintenance.md](zfs-pool-maintenance.md) — quiescing everything that touches `tank` so the pool can be exported, and bringing it back in order.
- [versitygw-deploy.md](versitygw-deploy.md) — how the s3-hot / s3-bulk gateways are stood up and operated.
- [versitygw-cli.md](versitygw-cli.md) — driving the versitygw tool (accounts, buckets, IAM).

## LLM observability

- [langfuse.md](langfuse.md) — operating Langfuse: health, adding projects, onboarding, upgrades, and the migration/SSO/S3 failure modes.

## Analytics

- [metabase.md](metabase.md) — operating Metabase: standup, adding a database, upgrades (one-way migrations), and the grant/SSO failure modes.

## CI Gate

- [ci-gate.md](ci-gate.md) — bootstrap, Audit→Enforce rollout, key rotation, gate version bump, deploy-denied diagnosis.

## Identity / invites

- [invite-authentik-reader.md](invite-authentik-reader.md) — the Authentik read-only group reader backing the invite console.
- [authentik-email-otp.md](authentik-email-otp.md) — email one-time-code sign-up and passwordless sign-in (health, delivery failures, the auto-ban trap).

## Notifications

- [ntfy.md](ntfy.md) — self-hosted ntfy push-notification service (users, tokens, topic access, ops).

## Assistant

- [residuum.md](residuum.md) — Residuum platform assistant on the R730xd: deploy/upgrade, health, adding CLI tools, recovery.

## Cluster

- [k8s-cluster-ops.md](k8s-cluster-ops.md) — full standup, single-node rebuild/rejoin, and version upgrade sequences.

## Network / hardware

- [garage-relocation-cutover.md](garage-relocation-cutover.md) — staged garage relocation + EX50 router cutover plan and checkpoints.
- [ex50-console-access.md](ex50-console-access.md) — reaching the Digi EX50 CLI during bench bring-up.
- [ex50-dal-cli.md](ex50-dal-cli.md) — driving the EX50 DAL config (Admin CLI + `/bin/config` mechanics, gotchas, scheduled-script recipe).
- [aerohive-ap-setup.md](aerohive-ap-setup.md) — standalone WiFi setup for the AP630 + AP130.
- [sr2024-vlan-trunks.md](sr2024-vlan-trunks.md) — converting the SR2024 uplink ports to VLAN trunks for downstream WiFi segmentation.
