# Platform Index — where things live

The navigation map for the repo. [`README.md`](README.md) is the platform's *shape* (architecture, machines, traffic flow); this is the *map* — when you need to work on a subsystem, start here to find its docs (why + how) and its code. Nothing here is loaded on every task; consult the entry for what you're actually touching.

Docs follow **README = shape, INDEX = listing**. The docs map is [`docs/README.md`](docs/README.md); the full doc listing is [`docs/INDEX.md`](docs/INDEX.md).

## Subsystems

Each entry: what it is → decisions (*why*) · runbook (*how to operate*) · integration guide (*how to consume from an app*, [docs/integration/](docs/integration/INDEX.md)) · code.

### CI Gate
Centralized CI gate — versioned `grizzly-gate` image runs per-language checks + SCA, cosign-signs passing image digests, Kyverno refuses unsigned images at admission. Gate *source* lives in its own repo ([Grizzly-Endeavors/grizzly-gate](https://github.com/Grizzly-Endeavors/grizzly-gate)); this platform owns the *integration*.
- **Why:** [ADR-028](docs/decisions/028-centralized-ci-gate.md) (gate + cosign + Kyverno), [029](docs/decisions/029-gate-config-honest-map.md) (honest map), [030](docs/decisions/030-cross-ecosystem-sca.md) (SCA), [027](docs/decisions/027-registry-zot.md) (zot registry).
- **How:** [runbooks/ci-gate.md](docs/runbooks/ci-gate.md) (operate) · **integrate:** [integration/deploy.md](docs/integration/deploy.md) (get an app onto the cluster through the gate) · overview [ci-gate.md](docs/ci-gate.md), threat model [ci-gate-coverage.md](docs/ci-gate-coverage.md).
- **Code:** `.github/workflows/gate.yaml` (reusable), `kubernetes/infrastructure/argo-workflows/build-gate-image.yaml` (build), `kubernetes/infrastructure/kyverno{,-policies}/` (admission), `docker/grizzly-gate/` (pointer stub). Signing key: 1Password item `cicd-cosign`.

### Secrets (1Password)
The `grizzly-platform` 1Password vault is the platform secrets source of truth. K8s reads via External Secrets Operator (`onepassword` ClusterSecretStore); Ansible reads via `op` lookups. Three service account tokens reach it and nothing else does.
- **Why:** [ADR-073](docs/decisions/073-retire-openbao.md) (1Password as the source of truth; OpenBao retired), [048](docs/decisions/048-first-party-app-secrets-domain.md) (app secrets domain).
- **How:** [onepassword-quickref.md](docs/runbooks/onepassword-quickref.md) (**start here** — tokens, rate limits, alert response, rotation, standing up a control node).
- **Integrate:** [integration/secrets.md](docs/integration/secrets.md) (land a credential in your namespace via ESO / Ansible).
- **Code:** `ansible/playbooks/setup-1password-eso.yml`, `ansible/vars/onepassword_secrets.yml`, `kubernetes/infrastructure/external-secrets/`, `kubernetes/infrastructure/external-secrets-stores/onepassword-store.yaml`.

### Mail (Stalwart)
Self-hosted Stalwart mail server, in-cluster, own-MX inbound (VPS HAProxy → WG tunnel) + SMTP2GO outbound smarthost, SPF/DKIM/DMARC aligned. Roundcube webmail behind Authentik. State on foundation Postgres + s3-hot blob store.
- **Why:** [ADR-050](docs/decisions/050-stalwart-mail-server.md) (Stalwart), [051](docs/decisions/051-haproxy-l4-mail-ingress.md) (HAProxy L4 ingress), [052](docs/decisions/052-in-cluster-acme-cert-for-mail.md) (ACME cert), [054](docs/decisions/054-cloudflare-email-routing-interim-inbound.md) (interim inbound, superseded), [058](docs/decisions/058-roundcube-webmail.md) (webmail).
- **How:** [mail.md](docs/runbooks/mail.md) (**start here**), [stalwart-cli.md](docs/runbooks/stalwart-cli.md) (config CLI).
- **Integrate:** [integration/mail.md](docs/integration/mail.md) (send transactional mail from an app — submission creds + DMARC alignment).
- **Code:** `kubernetes/infrastructure/stalwart/` + `kubernetes/clusters/grizzly-platform/stalwart.yaml`, `ansible/playbooks/configure-stalwart.yml` + `ansible/files/stalwart/plan.json`.

### Storage & foundation stores
- **Desktop share:** [runbooks/desktop-nfs.md](docs/runbooks/desktop-nfs.md) (on-demand `/mnt/pool` mount).
Durable app state lives on the R730xd foundation stores, never node disks: Postgres, kv-cache (Valkey), ClickHouse (OLAP, `:8123`/`:9000`), and versitygw S3 (s3-hot on ZFS `:7070`, s3-bulk on MergerFS `:7072`).
- **Why:** [ADR-003](docs/decisions/003-foundation-stores-on-r730xd.md) (foundation stores), [004-zfs](docs/decisions/004-zfs-iscsi-for-k8s-storage.md), [015](docs/decisions/015-dynamic-storage-provisioning.md) (democratic-csi), [055](docs/decisions/055-s3-object-store-versitygw.md) (versitygw), [056](docs/decisions/056-redis-to-valkey.md) (Valkey), [072](docs/decisions/072-immich-on-foundation-stores-and-sso.md) (vector extensions in the Postgres image).
- **Postgres image:** built on the R730xd from `ansible/roles/r730xd-postgres/files/Dockerfile` — stock `postgres:16` plus pgvector + VectorChord, with `vchord.so` preloaded. Extension versions are pinned in the role's defaults; a bump is a rebuild, not a tag change.
- **How:** [versitygw-deploy.md](docs/runbooks/versitygw-deploy.md), [versitygw-cli.md](docs/runbooks/versitygw-cli.md).
- **Integrate:** [integration/postgres.md](docs/integration/postgres.md) (database), [integration/valkey.md](docs/integration/valkey.md) (cache), [integration/s3.md](docs/integration/s3.md) (object storage), [integration/clickhouse.md](docs/integration/clickhouse.md) (analytical/OLAP).
- **Code:** `ansible/roles/r730xd-{zfs,s3-hot,s3-bulk,snapraid}/`, `ansible/playbooks/deploy-foundation-stores.yml`.

### Identity & invites (Authentik)
Authentik is the central IdP; invitation-gated enrollment via a cookie-bridged invite broker, by social provider or by email one-time code; app-library visibility scoped by group policy.
- **Why:** [ADR-033](docs/decisions/033-central-identity-authentik.md), [037](docs/decisions/037-authentik-config-as-code-blueprints.md) (config-as-code), [039](docs/decisions/039-authentik-social-federation-invitation-enrollment.md)–[043](docs/decisions/043-invite-admin-ui-forward-auth.md) (federation/invites), [049](docs/decisions/049-app-visibility-scoped-via-group-policy-bindings.md), [066](docs/decisions/066-email-otp-passwordless-signin.md) (email codes, passwordless).
- **How:** [invite-authentik-reader.md](docs/runbooks/invite-authentik-reader.md), [authentik-email-otp.md](docs/runbooks/authentik-email-otp.md).
- **Integrate:** [integration/sso.md](docs/integration/sso.md) (put an app behind Authentik — OIDC or forward-auth — and onboard people).
- **Code:** `kubernetes/infrastructure/authentik/`; invite broker in the sibling `grizzly-invite` repo.

### Observability
Prometheus / Loki / Tempo / Grafana on the R730xd.
- **Why:** [ADR-004](docs/decisions/004-observability-stack-on-r730xd.md). **How (operate):** [monitoring.md](docs/monitoring.md). **Integrate:** [integration/observability.md](docs/integration/observability.md) (emit logs/metrics/traces from an app). **Code:** `ansible/roles/r730xd-{prometheus,loki,tempo,grafana}/`, `ansible/playbooks/deploy-observability.yml`.

### Notifications (ntfy)
Self-hosted ntfy — a shared platform push-notification service. Any app publishes to a topic over HTTP; phones/browsers/services subscribe; supports interactive action buttons (approve/deny callbacks). Private (deny-all + tokens), on `ntfy.grizzly-endeavors.com`.
- **Why:** [ADR-061](docs/decisions/061-ntfy-notification-service.md).
- **How:** [runbooks/ntfy.md](docs/runbooks/ntfy.md) (mint users/tokens, grant topics, ops).
- **Integrate:** [integration/ntfy.md](docs/integration/ntfy.md) (publish, subscribe, action buttons).
- **Code:** `kubernetes/infrastructure/ntfy/` + `kubernetes/clusters/grizzly-platform/ntfy.yaml`.

### LLM observability (Langfuse)
Langfuse on `langfuse.grizzly-endeavors.com` — traces, token/cost accounting, prompt management and eval scores for the platform's first-party agents (Gary in grizzly-gameservers first). Behind Authentik; projects are unlimited, so each agentic app gets its own. Every bundled Bitnami sub-chart is disabled and pointed at the foundation stores instead.
- **Why:** [ADR-064](docs/decisions/064-langfuse-llm-observability.md) (Langfuse + ClickHouse as a foundation store).
- **How:** [runbooks/langfuse.md](docs/runbooks/langfuse.md) (operate, add projects, upgrade, failure modes) · **integrate:** [integration/clickhouse.md](docs/integration/clickhouse.md) (use the ClickHouse store from an app).
- **Code:** `kubernetes/infrastructure/langfuse/` + `kubernetes/clusters/grizzly-platform/langfuse.yaml`, `ansible/playbooks/setup-langfuse-stores.yml`, `ansible/roles/r730xd-clickhouse/`.

### Analytics (Metabase)
Metabase on `analytics.grizzly-endeavors.com` — dashboards and ad-hoc exploration over the platform's own data (the grizzly-gameservers product event log and occupancy series first, plus Langfuse's ClickHouse). Behind Authentik forward-auth scoped to `grizzly-admins`. Reads every data source through a `metabase_ro` account holding SELECT and nothing else; owns only its own database.
- **Why:** [ADR-065](docs/decisions/065-metabase-analytics-service.md) (Metabase + read-only store accounts).
- **How:** [runbooks/metabase.md](docs/runbooks/metabase.md) (standup, adding a database, upgrades, failure modes) · **integrate:** [integration/metabase.md](docs/integration/metabase.md) (expose your app's database).
- **Code:** `kubernetes/infrastructure/metabase/` + `kubernetes/clusters/grizzly-platform/metabase.yaml`, `ansible/playbooks/setup-metabase-stores.yml`, `kubernetes/infrastructure/authentik/blueprints/metabase.yaml`, `scripts/metabase-add-database.sh`.

### Assistant (Residuum)
Residuum personal agent on the R730xd — a first-party AI assistant that helps operate the platform. Runs the **stock** upstream image (no custom build) as a systemd-managed compose service; external CLIs come from a read-only tools volume on its PATH, so adding a tool needs no rebuild. Browser access is via residuum's outbound Cloud relay only — no published port, no ingress rule. It changes the platform through PRs and can merge its own, with Flux applying on merge — so every change is recorded and revertable, but it can reach production unattended.
- **Why:** [ADR-062](docs/decisions/062-residuum-platform-assistant.md).
- **How:** [runbooks/residuum.md](docs/runbooks/residuum.md) (deploy/upgrade, health, adding tools, recovery).
- **Code:** `ansible/playbooks/deploy-residuum.yml` + `ansible/roles/r730xd-residuum/`.

### Cluster, ingress & networking
Four-node kubeadm cluster (Cilium, Flux, ingress-nginx). Public ingress: VPS Caddy → WireGuard tunnel → R730xd DNAT → NodePort → ingress-nginx. Border router is the Digi EX50 (`10.0.0.1`); downstream WiFi is segmented into tagged VLANs (platform native VLAN 1, restricted VLAN 20, trusted VLAN 30) trunked over the SR2024 to the APs.
- **Why:** [ADR-014](docs/decisions/014-k8s-cluster-stack.md) (stack), [016](docs/decisions/016-single-control-plane.md), [067](docs/decisions/067-containerd-from-docker-repo.md) (containerd source), [068](docs/decisions/068-k8s-135-stepped-upgrade.md) (version upgrades), [019](docs/decisions/019-ingress-and-tls-termination.md) (ingress/TLS), [034](docs/decisions/034-in-cluster-wireguard-encryption.md)–[036](docs/decisions/036-internal-dns-zone.md) (in-cluster net); [044](docs/decisions/044-digi-ex50-as-off-the-shelf-router.md) (EX50 router), [046](docs/decisions/046-platform-network-segmentation-via-home-eviction.md) + [060](docs/decisions/060-downstream-wifi-segmentation.md) (segmentation). **How:** [runbooks/k8s-cluster-ops.md](docs/runbooks/k8s-cluster-ops.md) (standup/rejoin/upgrade), [network.md](docs/network.md), [nodeport-allocation.md](docs/nodeport-allocation.md); WiFi VLANs: [sr2024-vlan-trunks.md](docs/runbooks/sr2024-vlan-trunks.md) + [aerohive-ap-setup.md](docs/runbooks/aerohive-ap-setup.md); EX50 config `ansible/playbooks/configure-ex50.yml`.

## Active work

In-flight, multi-phase threads and where we left off: [docs/in-progress/INDEX.md](docs/in-progress/INDEX.md). Discrete bugs/blockers are GitHub issues.

## Repo areas

- `ansible/` — playbooks, roles, inventory for R730xd + VPS.
- `kubernetes/` — Flux-managed apps + infrastructure (`infrastructure/`, `clusters/grizzly-platform/`).
- `docker/` — Compose projects on the R730xd (foundation stores, observability).
- `configs/`, `scripts/` — machine configs and shell utilities.
- `docs/` — architecture, operations, decisions ([map](docs/README.md)).
- `archive/` — pre-2026 configs + the completed 2026 migration record.
