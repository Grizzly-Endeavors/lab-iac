# Hardware Inventory

Machines, specs, and live roles. This is the day-to-day "what's where" reference.

> **IP addresses:** Authoritative values are in `ansible/inventory/group_vars/all/network.yml`. This doc renders the Jinja vars literally so it doesn't drift from the source of truth.

**Update when:** a machine is added, removed, or takes on a different role; a disk is replaced; firmware/OS changes materially affect operations.

Last updated: 2026-07-08 (EX50 live as the router/gateway at 10.0.0.1; AP630 + AP130 #1 live in the standalone roaming hive)

---

## Active K8s Cluster Nodes

All four nodes are live on v1.33.10. Cilium CNI, Flux GitOps.

### dell-inspiron-15 — Control Plane

| Spec | Value |
|------|-------|
| Model | Dell Inspiron 15-3567 |
| Form factor | Laptop |
| CPU | Intel i3-7100U — 2C/4T @ 2.7 GHz |
| RAM | 8 GB |
| Storage | Local SSD (boot) |
| GPU | None |
| Network | `{{ dell_inspiron_ip }}` |
| Role | K8s control plane (single-node etcd, apiserver, scheduler, controller-manager) — see [ADR-016](decisions/016-single-control-plane.md) |
| Boot | Local disk ([ADR-013](decisions/013-local-disk-over-pxe-boot.md)) |

### quanta — Worker

| Spec | Value |
|------|-------|
| Model | Quanta QSSC-2ML |
| Form factor | 2U rackmount |
| CPU | 2× Intel Xeon E5-2670 (Sandy Bridge-EP) — 8C/16T each = 16C/32T total @ 2.6 GHz (turbo 3.3 GHz) |
| RAM | 64 GB DDR3 1333 MHz |
| Storage | 240 GB SATA SSD (local boot); 6× internal SATA bays (not hot-swap), most empty |
| GPU | None |
| Network | 4-port NIC via PCIe riser; OS IP `{{ quanta_ip }}`; BMC/IPMI `{{ quanta_bmc_ip }}` |
| Role | K8s worker — primary compute workhorse |
| Boot | Local disk |

### intel-nuc — Worker

| Spec | Value |
|------|-------|
| Model | Intel NUC12SNKi72 |
| Form factor | NUC (mini PC) |
| CPU | Intel Core i7-12700H — 14C/20T (6P+8E) |
| RAM | 64 GB |
| Storage | Internal NVMe (local boot) |
| GPU | Intel ARC (dead — headless worker only; display via USB-C when needed) |
| Network | `{{ intel_nuc_ip }}` |
| Role | K8s worker |
| Boot | Local disk |
| Power restore | BIOS → Power → **After Power Failure: Power On**. Manual setting — the NUC has no BMC, so it can't be managed with IaC and doesn't survive a BIOS reset. Without it this is the one node that stays down after a power cut while the rest of the cluster returns on its own. |

### optiplex — Worker

| Spec | Value |
|------|-------|
| Model | Dell Optiplex 9020 SFF |
| Form factor | SFF desktop |
| CPU | Intel i7-4790 — 4C/8T |
| RAM | 32 GB |
| Storage | Local SSD (boot) |
| GPU | None |
| Network | `{{ optiplex_ip }}` |
| Role | K8s worker (previously the standalone "deb-web" web/host/Palworld box — that role has been retired; see [ADR-022](decisions/022-palworld-decommissioned.md)) |
| Boot | Local disk |

---

## Active Standalone Infrastructure

### r730xd — Storage + Observability + Foundation Stores

| Spec | Value |
|------|-------|
| Model | Dell PowerEdge R730xd |
| Form factor | 2U rackmount (extended storage chassis) |
| CPU | 1× Intel Xeon E5-2630 v3 — 8C/16T @ 2.4 GHz, 85W TDP (second socket empty) |
| RAM | 32 GB DDR4 ECC (24 DIMM slots total) |
| NIC | Broadcom 4-port GbE 5720-t rNDC |
| Drive bays | 12× 3.5" front + 2× 2.5" rear |
| RAID | Dell PERC H730 Mini |
| PSUs | 2× 750W redundant (Delta) |
| iDRAC | `{{ r730xd_idrac_ip }}`, SSH racadm working (no Enterprise license — no virtual media) |
| Service tag | 45L1DH2 |
| OS | Debian 13.4 (Trixie), UEFI boot |
| OS IP | `{{ r730xd_ip }}` |
| Boot drive | Samsung SSD 850 EVO 250GB in bay 12 (rear 2.5"), non-RAID |
| Storage pools | See "Storage layout" below |
| Role | Storage backbone, observability stack, foundation stores (Postgres / kv-cache / ClickHouse / s3-hot / s3-bulk), ingress tunnel terminator |

**Storage layout (R730xd):**

| Pool | Drives | Usable | Purpose |
|------|--------|--------|---------|
| MergerFS pool (`/mnt/pool`) | 5×3TB data + 2×4TB SnapRAID parity (bays 0/3 parity, 1/2/4/5/8 data) | 15 TB | Bulk/cold data, K8s `nfs-mergerfs` StorageClass, s3-bulk (versitygw) |
| ZFS pool `tank` (`/mnt/zfs`) | 3×2TB raidz1 (bays 9/10/11) | ~3.6 TB | Latency-sensitive services (Postgres/kv-cache/ClickHouse/s3-hot (versitygw)/Prometheus/Loki/Tempo/Grafana), K8s `iscsi-zfs` StorageClass (via democratic-csi) |

Decisions: [ADR-003](decisions/003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-004](decisions/004-observability-stack-on-r730xd.md) (observability), [ADR-004 zfs](decisions/004-zfs-iscsi-for-k8s-storage.md) (ZFS+iSCSI), [ADR-007](decisions/007-3tb-data-drive-direct-to-pool.md) (3TB direct mount), [ADR-012](decisions/012-hot-services-on-zfs-minio-split.md) (hot services on ZFS), [ADR-015](decisions/015-dynamic-storage-provisioning.md) (democratic-csi).

### proxy-vps — Hetzner Cloud

| Spec | Value |
|------|-------|
| Provider | Hetzner Cloud |
| SSH | Port 2222 |
| Public IP | `{{ proxy_vps_public_ip }}` |
| Role | Caddy reverse proxy with wildcard `*.bearflinn.com` TLS (Cloudflare DNS-01). Routes to K8s via dedicated WireGuard tunnel + iptables DNAT on R730xd ([ADR-019](decisions/019-ingress-and-tls-termination.md)). Also hosts PostHog reverse proxy and a few domain redirects. |
| Domains | `*.bearflinn.com` (wildcard to K8s), `pennydreadfulsfx.com`, `gin-house.bearflinn.com` (Home Assistant over NetBird), `ph.bearflinn.com` (PostHog proxy) |

---

## Network Equipment

### Aerohive SR2024 Switch

| Spec | Value |
|------|-------|
| Model | Aerohive SR2024 |
| Ports | 24× 1GbE + 2× SFP (+ 2× combo GbE/SFP) |
| PoE | 802.3at (PoE+), powering APs |
| Firmware | HiveOS 6.5r8 (2017) |
| Mgmt access | `{{ sr2024_ip }}` (static mgt0, DHCP client disabled); SSH/web, default creds `admin`/`aerohive`. Modern SSH clients need legacy algorithms — see [aerohive-cli-reference.md](aerohive-cli-reference.md). |
| Role | Lab backbone — all lab machines connect here (untagged VLAN 1). Upstream gateway is the EX50 (`10.0.0.1`). Uplink ports to the EX50 (`eth1/1`) + APs (`eth1/3`, `eth1/4`) are VLAN 20/30 trunks carrying native VLAN 1 untagged ([ADR-060](decisions/060-downstream-wifi-segmentation.md), [runbooks/sr2024-vlan-trunks.md](runbooks/sr2024-vlan-trunks.md)). |
| Capabilities | 802.1Q VLANs, LACP, trunk/access ports — all verified |
| Known quirk | PSE (PoE) subsystem can **wedge** — all ports `unknown`/0 W despite healthy config; only a physical power-pull recovers it. Monitoring deferred to post-migration. See [PSE wedge](aerohive-cli-reference.md#poe-troubleshooting--the-pse-wedge) + [monitoring plan](exploration/sr2024-poe-monitoring.md). |

### Aerohive WiFi APs

| AP | Model | WiFi | Firmware | Status |
|----|-------|------|----------|--------|
| AP630 | AP630 | 4×4:4 MU-MIMO, 802.11ac Wave 2 | Stock HiveOS IQ Engine 10.6r7 (restored 2026-04-03, [ADR-011](decisions/011-ap630-restored-to-stock-wifi-ap.md)) | Live (2026-07-07) — primary in the standalone roaming hive, see [network.md](network.md) and [aerohive-ap-setup.md](runbooks/aerohive-ap-setup.md) |
| AP230 | AP230 | 3×3:3 MIMO, 802.11ac Wave 1 | HiveOS 8.1r1 | Factory reset, CAPWAP disabled; mounting pending ([ADR-009](decisions/009-start-with-ap230-only.md)) |
| AP130 #1 | AP130 | 802.11ac Wave 1 | HiveOS 6.5r8b | Live (2026-07-07) — secondary in the standalone roaming hive |
| AP130 #2 | AP130 | 802.11ac Wave 1 | HiveOS 6.5r1b | Spare; older firmware + 1 bad NAND block (consider updating) |

---

## Standalone / Non-cluster Machines

### Mini PC (AMD C60) — Jumpbox

| Spec | Value |
|------|-------|
| CPU | AMD C60 APU — 2C/2T @ 1.0 GHz (1.33 boost), Bobcat x86-64 |
| RAM | 4 GB |
| Storage | SSD (from Optiplex / Inspiron salvage) |
| Role | Dedicated jumpbox — SSH gateway, `kubectl` + `helm`, Claude Code, stats display |
| Status | Build script + Sway configs ready; imaging pending |

---

## Future / Pending Hardware

Tracked here rather than in the active sections so the active tables stay truthful.

### tower-pc — Pending K8s Join

| Spec | Value |
|------|-------|
| Model | Custom full tower |
| CPU | Intel i7-4790 — 4C/8T @ 3.6–4.0 GHz |
| RAM | 24 GB |
| Storage | 128 GB NVMe, 240 GB SATA SSD (OS) — local boot |
| GPU | None planned (PSU insufficient — GPU fleet moves to the new inference host below) |
| Network | `{{ tower_pc_ip }}` (reserved) |
| Planned role | Plain K8s worker |
| Status | Physically in/near the closet. Not yet joined. Will be added to `ansible/inventory/lab-nodes.yml` at join time. See [ADR-021](decisions/021-off-the-shelf-router-tower-pc-as-worker.md). |
| IaC | Hostname/IP reserved in `ansible/inventory/group_vars/all/network.yml`; joins via `ansible/playbooks/join-k8s-workers.yml`. |
| Previous history | Was the K8s GPU-workload worker + planned router + planned GPU-inference host. All three roles retired in ADR-021. |

### GPU inference host — Being Built

| Spec | Value |
|------|-------|
| Hostname | TBD |
| Form factor | TBD |
| Planned GPUs | NVIDIA GTX 1080 Ti (11 GB), GTX 1060 (3 GB), GTX 1050 Ti (4 GB). GTX 760 (2 GB) is likely not worth a slot. |
| Planned role | Standalone inference host (Ollama / vLLM / text-generation-inference TBD). Consumed over the LAN by cluster workloads and developer tools. |
| Status | Hardware in progress; specs / IP / ADR reserved until the machine lands. Kept out of the cluster intentionally so inference workloads don't share a drain/reboot cadence with cluster workers. |

### Digi EX50 — Live (router / gateway)

| Spec | Value |
|------|-------|
| Model | Digi EX50 (5G enterprise cellular router; runs scriptable Digi Accelerated Linux / DAL) |
| Ports | 2× 2.5 GbE (one WAN, one LAN — no built-in switch fabric), WiFi 6, dual-SIM 5G/LTE |
| Power | DC barrel adapter (the SR2024's PoE is dead — [#84](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/84)) |
| Role | The router/gateway at `10.0.0.1` — NAT, DHCP, DNS forwarding, firewall. Routes the platform (native VLAN 1) plus the downstream `restricted` (VLAN 20) and `trusted` (VLAN 30) WiFi segments ([ADR-060](decisions/060-downstream-wifi-segmentation.md)). Xfinity gateway in bridge mode. Own WiFi off (Aerohive serves WiFi). 5G not enabled (no cellular plan). Config in IaC via the DAL Admin CLI (`configure-ex50.yml`). |
| Status | **Live** — flat cutover (Checkpoint C) done 2026-07-08. See [ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md) and [runbooks/garage-relocation-cutover.md](runbooks/garage-relocation-cutover.md). |
| Still to come | Evicting the *wired* home drops off VLAN 1 ([ADR-046](decisions/046-platform-network-segmentation-via-home-eviction.md); the WiFi segments are done per [ADR-060](decisions/060-downstream-wifi-segmentation.md)), ingress-tunnel relocation off R730xd ([ADR-047](decisions/047-ingress-tunnel-relocation-to-ex50.md), Ckpt E), internal DNS resolver move ([ADR-036](decisions/036-internal-dns-zone.md)). |
| Firmware gate | WireGuard needs DAL ≥ 24.3.28.88 (required before ingress relocation). |

### APC Back-UPS RS 1500 — Batteries Dead

| Spec | Value |
|------|-------|
| Capacity | 1500 VA / 865 W |
| Output | Simulated sine wave (stepped approximation) |
| Data port | RJ45 (APC proprietary) — needs APC 940-0127 or compatible cable for NUT |
| Status | Batteries dead; replacement + NUT integration deferred ([ADR-006](decisions/006-proceed-without-ups.md)). |
| Compatibility | Server PSUs (R730 / Quanta) require pure sine; use only for consumer-PSU machines (Inspiron, Optiplex, Tower PC, switch) once batteries are replaced. |

### Spare GPUs

| GPU | VRAM | Planned home |
|-----|------|--------------|
| NVIDIA GTX 1080 Ti | 11 GB | New GPU inference host |
| NVIDIA GTX 1060 | 3 GB | New GPU inference host |
| NVIDIA GTX 1050 Ti | 4 GB | New GPU inference host (low power, no external power connector on most cards) |
| NVIDIA GTX 760 | 2 GB | Spare — likely not worth a slot |

---

## Aggregate Resources — Live Cluster (2026-04-17)

| Resource | Total |
|----------|-------|
| Control plane nodes | 1 (Inspiron) |
| Worker nodes | 3 (Quanta, Intel NUC, Optiplex) |
| CPU cores (all nodes) | 36C/64T (Inspiron 2C/4T + Quanta 16C/32T + NUC 14C/20T + Optiplex 4C/8T) |
| RAM (workers) | 160 GB (64 + 64 + 32) |
| RAM (control plane) | 8 GB |
| GPUs | None in cluster (by design — see GPU inference host above) |

Once Tower PC joins: +4C/8T and +24 GB RAM → 40C/72T, 184 GB worker RAM.

## Aggregate Resources — All Available Hardware

| Resource | Value |
|----------|-------|
| CPU cores (all lab hardware) | ~52C/88T — live cluster 36C/64T + R730xd 8C/16T + Tower PC 4C/8T (pending join) + jumpbox 2C/2T |
| RAM (all lab hardware) | ~228 GB — live cluster 168 GB + R730xd 32 GB + Tower PC 24 GB + jumpbox 4 GB |
| Storage (R730xd pools, usable) | ~18.6 TB (15 TB MergerFS + 3.6 TB ZFS) |
| Network | 24-port managed GbE switch, 4× WiFi APs (various generations) |
| Physical machines (infra) | 5 live (Inspiron, Quanta, NUC, Optiplex, R730xd) + 1 pending (Tower PC) + 1 support (jumpbox) |
| Physical machines (future) | GPU inference host (new build), off-the-shelf router |

Not infrastructure: the operator's on-the-go dev laptop (GS66 Stealth) is a personal machine and deliberately not tracked here.

---

## Pending Work

- [ ] UPS: replace batteries, wire NUT.
- [ ] Finish GPU inference host build; assign IP + hostname and write its ADR.
- [x] Relocate the platform to the garage — done 2026-07-05 (physical move during a power outage; SR2024 + all machines came back on the same flat 10.0.0.x network). See [ADR-045](decisions/045-platform-relocation-to-garage.md).
- [ ] Deploy the Digi EX50 as router (was originally planned as one staged window with the relocation above, but the move happened on its own; the router cutover is still outstanding). See [runbooks/garage-relocation-cutover.md](runbooks/garage-relocation-cutover.md), [ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md).
- [ ] Configure L3 segmentation on the EX50/SR2024 (evict home to its own subnet — [ADR-046](decisions/046-platform-network-segmentation-via-home-eviction.md)).
- [ ] Mount remaining APs; verify coverage.
- [ ] Join Tower PC to the cluster (see [ADR-021](decisions/021-off-the-shelf-router-tower-pc-as-worker.md)).
