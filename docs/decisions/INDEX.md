# ADR index

One line per decision, grouped by domain. See [`README.md`](README.md) for what ADRs are and the numbering quirks. Numbers in rough creation order; a couple repeat (the slug disambiguates).

## Router & network hardware (the router saga)

- [001-tower-pc-as-router](001-tower-pc-as-router.md) — start with the tower PC as the lab router.
- [003-ap630-as-router](003-ap630-as-router.md) — replace the tower PC router with an AP630.
- [010-ap630-iudma-limit-requires-rdp](010-ap630-iudma-limit-requires-rdp.md) — AP630's 10 Mbps iuDMA cap forces RDP for router use.
- [011-ap630-restored-to-stock-wifi-ap](011-ap630-restored-to-stock-wifi-ap.md) — give up on AP630-as-router; restore stock HiveOS, use as a WiFi AP.
- [009-start-with-ap230-only](009-start-with-ap230-only.md) — bring up WiFi with the AP230 alone first.
- [008-keep-existing-switch-chain-for-home](008-keep-existing-switch-chain-for-home.md) — keep the existing switch chain for the home network.
- [021-off-the-shelf-router-tower-pc-as-worker](021-off-the-shelf-router-tower-pc-as-worker.md) — buy an off-the-shelf router; the tower PC joins the cluster as a plain worker.
- [044-digi-ex50-as-off-the-shelf-router](044-digi-ex50-as-off-the-shelf-router.md) — the Digi EX50 is that router.

## Relocation & segmentation

- [045-platform-relocation-to-garage](045-platform-relocation-to-garage.md) — move the platform hardware to the garage.
- [046-platform-network-segmentation-via-home-eviction](046-platform-network-segmentation-via-home-eviction.md) — segment the platform off the home LAN.
- [047-ingress-tunnel-relocation-to-ex50](047-ingress-tunnel-relocation-to-ex50.md) — home the ingress tunnel on the EX50.
- [060-downstream-wifi-segmentation](060-downstream-wifi-segmentation.md) — split downstream WiFi into trusted + restricted VLANs (refines 046); platform stays native VLAN 1.

## Cluster & compute

- [014-k8s-cluster-stack](014-k8s-cluster-stack.md) — kubeadm + Cilium + nginx-ingress + Flux.
- [016-single-control-plane](016-single-control-plane.md) — run a single control-plane node.
- [013-local-disk-over-pxe-boot](013-local-disk-over-pxe-boot.md) — local-disk installs for K8s nodes over PXE.
- [005-nfs-root-for-pxe-nodes](005-nfs-root-for-pxe-nodes.md) — NFS-root off ZFS for PXE-booted nodes (early approach).
- [018-argo-workflows](018-argo-workflows.md) — Argo Workflows as the workflow engine.

## Storage & foundation stores

- [003-foundation-stores-on-r730xd](003-foundation-stores-on-r730xd.md) — durable app state lives on the R730xd foundation stores, not node disks.
- [004-zfs-iscsi-for-k8s-storage](004-zfs-iscsi-for-k8s-storage.md) — ZFS + iSCSI for K8s block storage.
- [015-dynamic-storage-provisioning](015-dynamic-storage-provisioning.md) — dynamic provisioning via democratic-csi.
- [007-3tb-data-drive-direct-to-pool](007-3tb-data-drive-direct-to-pool.md) — 3TB drive straight into the MergerFS pool.
- [012-hot-services-on-zfs-minio-split](012-hot-services-on-zfs-minio-split.md) — hot services on ZFS; MinIO split obs/bulk (historical — MinIO since removed).
- [055-s3-object-store-versitygw](055-s3-object-store-versitygw.md) — MinIO → Versity S3 Gateway.
- [072-versitygw-iam-on-internal-file-store](072-versitygw-iam-on-internal-file-store.md) — versitygw keeps its S3 accounts in its own file store on ZFS, not an external IAM backend.
- [056-redis-to-valkey](056-redis-to-valkey.md) — Redis → Valkey on a backend-agnostic kv-cache slot.
- [070-zfs-pool-stable-device-paths](070-zfs-pool-stable-device-paths.md) — the ZFS pool addresses vdevs by `/dev/disk/by-id`, and the creation guard detects exported pools.

## Cluster networking, DNS & internal TLS

- [019-ingress-and-tls-termination](019-ingress-and-tls-termination.md) — VPS Caddy → WireGuard → NodePort → ingress-nginx topology.
- [034-in-cluster-wireguard-encryption](034-in-cluster-wireguard-encryption.md) — transparent in-cluster encryption via Cilium WireGuard.
- [035-internal-tls-openbao-pki](035-internal-tls-openbao-pki.md) — internal TLS foundation via OpenBao PKI (never implemented; superseded by 073).
- [036-internal-dns-zone](036-internal-dns-zone.md) — internal DNS zone for name-based addressing.

## Observability

- [004-observability-stack-on-r730xd](004-observability-stack-on-r730xd.md) — Prometheus/Loki/Tempo/Grafana on the R730xd.

## CI/CD, registry & builds

- [017-arc-v2-github-runners](017-arc-v2-github-runners.md) — ARC v2 for GitHub Actions runners.
- [020-app-delivery-model](020-app-delivery-model.md) — app delivery via per-repo Flux sources.
- [059-app-self-service-provisioning](059-app-self-service-provisioning.md) — apps self-provision foundation resources via an aggregate `App` CR + additive-only controllers (Proposed; design in exploration/).
- [025-personal-apps-in-separate-repo](025-personal-apps-in-separate-repo.md) — personal apps live in a separate `lab-apps` repo.
- [027-registry-zot](027-registry-zot.md) — replace docker/distribution with zot for OCI referrers.
- [028-centralized-ci-gate](028-centralized-ci-gate.md) — central CI gate: cosign attestation + Kyverno admission.
- [029-gate-config-honest-map](029-gate-config-honest-map.md) — mandatory `gate-config.json` honest map.
- [030-cross-ecosystem-sca](030-cross-ecosystem-sca.md) — cross-ecosystem SCA (OSV-Scanner + Trivy fs), fetched fresh.
- [031-registry-cache-persistent-pvc](031-registry-cache-persistent-pvc.md) — fix the zot dedupe-restore storm; persistent metaDB.
- [032-registry-pullthrough-cache](032-registry-pullthrough-cache.md) — transparent pull-through cache on the zot registry.
- [057-container-builds-buildkit](057-container-builds-buildkit.md) — Kaniko → BuildKit for image builds.
- [063-gate-runs-in-cluster](063-gate-runs-in-cluster.md) — the CI gate runs as a K8s Job (containerd-cached image, cosign key off the runners).
- [069-kyverno-failurepolicy-tracks-failureaction](069-kyverno-failurepolicy-tracks-failureaction.md) — an Audit policy uses `failurePolicy: Ignore` so a webhook timeout can't block admission.
- [071-self-hosted-gitlab-runners](071-self-hosted-gitlab-runners.md) — GitLab CI on a split namespace pair: job code gets internet-only egress, no token, no API, rootless BuildKit.

## Secrets

- [073-retire-openbao](073-retire-openbao.md) — **current.** OpenBao retired; the `grizzly-platform` 1Password vault is the secrets source of truth.
- [048-first-party-app-secrets-domain](048-first-party-app-secrets-domain.md) — first-party app secrets under a dedicated `apps/` domain.
- [023-self-hosted-openbao-on-r730xd](023-self-hosted-openbao-on-r730xd.md) — self-hosted OpenBao as the secrets source of truth (superseded by 073).
- [024-platform-secrets-on-openbao](024-platform-secrets-on-openbao.md) — platform secrets on OpenBao, ESO + AppRole (superseded by 073).

## Identity & invites (Authentik)

- [033-central-identity-authentik](033-central-identity-authentik.md) — Authentik as the central identity provider.
- [037-authentik-config-as-code-blueprints](037-authentik-config-as-code-blueprints.md) — Authentik config-as-code via file blueprints.
- [039-authentik-social-federation-invitation-enrollment](039-authentik-social-federation-invitation-enrollment.md) — social federation with invitation-gated enrollment.
- [040-invite-broker-cookie-bridged-enrollment](040-invite-broker-cookie-bridged-enrollment.md) — invite broker via cookie-bridged Authentik enrollment.
- [041-group-scoped-invites](041-group-scoped-invites.md) — group-scoped invites and the membership taxonomy.
- [042-multi-use-invites](042-multi-use-invites.md) — multi-use invites via a per-redemption nonce ledger.
- [043-invite-admin-ui-forward-auth](043-invite-admin-ui-forward-auth.md) — invite admin UI gated by Authentik forward-auth.
- [049-app-visibility-scoped-via-group-policy-bindings](049-app-visibility-scoped-via-group-policy-bindings.md) — app-library visibility via group policy bindings.
- [066-email-otp-passwordless-signin](066-email-otp-passwordless-signin.md) — email one-time-code enrollment; the code is the credential (no password).

## Apps & services

- [026-actual-budget-deployment](026-actual-budget-deployment.md) — Actual Budget self-hosted deployment.
- [038-nextcloud-on-foundation-stores-and-sso](038-nextcloud-on-foundation-stores-and-sso.md) — Nextcloud on foundation stores, S3 primary storage, Authentik SSO.
- [053-platform-services-domain-migration](053-platform-services-domain-migration.md) — platform services migrate to grizzly-endeavors.com.
- [061-ntfy-notification-service](061-ntfy-notification-service.md) — self-hosted ntfy as a shared platform push-notification service (deny-all + tokens, its own auth).
- [062-residuum-platform-assistant](062-residuum-platform-assistant.md) — Residuum agent on the R730xd; stock image + runtime tools volume, relay-only access, PR-only mutation.
- [064-langfuse-llm-observability](064-langfuse-llm-observability.md) — Langfuse as the shared LLM-observability service, on foundation stores with ClickHouse added as a fifth.
- [065-metabase-analytics-service](065-metabase-analytics-service.md) — Metabase as the analytics front-end, reading every data source through read-only store accounts.

## Mail (Stalwart)

- [050-stalwart-mail-server](050-stalwart-mail-server.md) — Stalwart as the platform mail server.
- [051-haproxy-l4-mail-ingress](051-haproxy-l4-mail-ingress.md) — HAProxy L4 mail ingress with PROXY protocol on the VPS.
- [052-in-cluster-acme-cert-for-mail](052-in-cluster-acme-cert-for-mail.md) — in-cluster ACME cert for mail (LE DNS-01 via Cloudflare).
- [054-cloudflare-email-routing-interim-inbound](054-cloudflare-email-routing-interim-inbound.md) — CF Email Routing as interim inbound (superseded by own-MX).
- [058-roundcube-webmail](058-roundcube-webmail.md) — Roundcube webmail, gated by Authentik forward-auth.

## Lifecycle & one-offs

- [002-r730-staging-vm-for-migration](002-r730-staging-vm-for-migration.md) — R730 staging VM for migration continuity.
- [006-proceed-without-ups](006-proceed-without-ups.md) — proceed without a UPS (battery replacement pending).
- [022-palworld-decommissioned](022-palworld-decommissioned.md) — Palworld server decommissioned indefinitely.
