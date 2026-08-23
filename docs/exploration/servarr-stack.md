# Servarr + Jellyfin Media Stack (exploration)

**Date:** 2026-07-06
**Status:** Exploring — no code yet. Design shape agreed; app-side choices (download clients, VPN provider, v1 scope) still open.

## Context

Pure exploration of what it takes to run the "Servarr" media-automation stack (Prowlarr + Sonarr/Radarr + Bazarr, a download client, and a Jellyfin media server) on the grizzly-platform cluster. The interesting part is that this workload deliberately fights two platform defaults — *prefer foundation stores over PVCs* and *grizzly-platform is public* — so most of the design is about where each piece of state lives and how access is gated without a client-side VPN.

Nothing here is committed. If adopted, this graduates to an ADR (media-stack storage exception) and the app manifests land in **lab-apps**, not this repo.

## Where it lives

- **Repo: lab-apps (private), not grizzly-platform.** Sonarr/Radarr/Prowlarr are legitimate FOSS and plenty of people run them in public homelab repos, so this isn't about the software being "dirty." The concrete risks are narrow: leaking private-tracker announce URLs / indexer definitions (which can get you banned from those trackers) — but routing all secrets through 1Password + ESO keeps the manifests clean and neutralizes that. The real reason it belongs in lab-apps is the existing routing rule: it's a personal/third-party app, and those go in lab-apps regardless of legality.
- One Flux Kustomization, its own namespace.

## Storage — split by access pattern (the crux)

This is the deliberate exception to *prefer foundation stores over PVCs*. Media is not SQL/KV/S3-shaped — it's a large POSIX tree that needs **hardlinks + atomic same-filesystem moves** (the TRaSH-guides reason instant imports don't double disk usage). S3/versitygw can't serve that role. So media wants a big RWX NFS share. Everything else is pushed onto the foundation stores as hard as each app allows.

Reconciling with the storage rule (see the [ADR-003](../decisions/003-foundation-stores-on-r730xd.md) amendment): **nothing touches a node's local disk.** Node disks hold the OS only. Every piece of durable state below lands on a foundation-provided backend (Postgres, NFS, or iSCSI-ZFS block), so there's a single central back-up/snapshot/restore story.

| Data | Home | Backend | Why |
|------|------|---------|-----|
| Media library + downloads | NFS `/mnt/pool`, single mount (`/data/media` + `/data/torrents` under one root) | MergerFS/SnapRAID | Hardlinks + atomic moves require one filesystem; POSIX, not S3 |
| Sonarr / Radarr / Prowlarr (+ Lidarr/Readarr) DBs | foundation **Postgres** (main + log DB) | ZFS | Native external-Postgres support; keeps the heavy relational state off SQLite entirely |
| Jellyseerr DB | foundation **Postgres** | ZFS | Supported in recent versions |
| Jellyfin (`library.db`) | **iSCSI-ZFS block PVC** | ZFS zvol | SQLite-only, no Postgres path; heavily exercised → wants a fast block device, **not** NFS |
| qBittorrent config + `.fastresume` | **iSCSI-ZFS block PVC** | ZFS zvol | Not a SQL app at all — file/config state, needs a small volume regardless |
| Bazarr config (optional, v1-skippable) | **iSCSI-ZFS block PVC** | ZFS zvol | SQLite-only, no Postgres path |

### Push everything possible to Postgres

The `.arr` .NET apps (Sonarr, Radarr, Prowlarr, Lidarr, Readarr) all support an external Postgres main + log DB — those move to the foundation Postgres cleanly. Jellyseerr supports Postgres too. This is the bulk of the relational state, and it lands where it belongs.

**The holdouts that physically can't use Postgres**, and stay on small iSCSI-ZFS block PVCs:
- **Bazarr** — Python with its own DB layer (not the shared .NET codebase); SQLite-only, long-standing open request, no Postgres support. Optional in v1.
- **Jellyfin** — SQLite-only (`library.db`); mid-migration to EF Core with only experimental chatter about other providers, nothing production-grade. Mandatory, can't move. Its SQLite is heavily exercised, so give it the fast iSCSI block device — do **not** put it on NFS.
- **qBittorrent** — not a database app; config files + resume data. "Postgres" doesn't apply; it just needs a small volume.

Going max-Postgres therefore doesn't eliminate block storage, it **shrinks** it: from "all configs on iSCSI" down to three small PVCs (or two if Bazarr is deferred). iSCSI-ZFS is the sanctioned block path ([ADR-004](../decisions/004-zfs-iscsi-for-k8s-storage.md); storage class `kubernetes/infrastructure/storage/iscsi-zfs-retain.yaml`, `Retain` reclaim). **Verify the class is actually provisioning** (ADR-004 status still reads "iSCSI pending" from April, but the registry PVC uses it — confirm it's `Bound` before committing config to it) and that SQLite-on-block is happy.

**SQLite must never sit on NFS** — lock contention corrupts it. That's the whole reason the holdouts get a block PVC rather than a slice of the media share.

## Access — Authentik, no client-side VPN

The goal is no VPN juggling. **Authentik forward-auth via ingress-nginx** gates the `.arr` web UIs with existing SSO — log in like every other bearflinn service, no Tailscale.

- **Service-to-service stays in-cluster, unauthenticated by SSO.** Prowlarr → Sonarr/Radarr sync, Bazarr → `.arr`, Jellyseerr → `.arr` all use **API keys**, not SSO. Those calls ride ClusterIP internally and never hit ingress, so forward-auth doesn't interfere. Only the human ingress path gets Authentik.
- **Jellyfin does NOT go behind forward-auth.** Its native/mobile/TV apps can't follow the SSO browser redirect. Use Jellyfin's own login (optionally Authentik as an OIDC provider via plugin, but TV apps still use Jellyfin creds). Same caution if qBittorrent's mobile app is used.

## The VPN you *do* want is a different VPN

Two unrelated VPNs — worth separating so "wire in a VPN" doesn't get conflated with juggling:

- **Access VPN (Tailscale)** — for *you* to reach apps. This is the juggling being avoided. **Authentik replaces it entirely. Gone.**
- **Egress VPN (gluetun sidecar)** — for the *torrent client's outbound traffic* only, so the home IP never hits a swarm. Always-on sidecar scoped to the qBittorrent pod, with a killswitch so a dropped tunnel can't leak. Zero juggling. Pick a provider with **port forwarding** if seed ratios matter (ProtonVPN / AirVPN / PIA still offer it; Mullvad dropped it). Creds → 1Password. Only the download client sits behind it; the `.arr` apps and Jellyfin route normally.

## Compute — GPU tower for Jellyfin

Jellyfin transcoding wants a GPU, and the diskless-era assumption is dead but the fleet still has no GPUs. Plan: **re-add the tower PC (GTX 1060) to the cluster** as a GPU node.

- The 1060 (Pascal, NVENC) handles H.264 and HEVC 8-bit transcodes fine.
- Needs `nvidia-container-toolkit` + the k8s device plugin, a GPU node label, and Jellyfin pinned via `nodeSelector`.
- The tower is a **different node profile** than the rest of the fleet (local disk + GPU) — a deliberate stateful/GPU exception. Note: per the no-node-disk rule, its local disk is still not a home for durable app state; that all lives on the foundation stores above. The tower is just where the GPU (and Jellyfin) live.

## Components (v1 sketch)

- **Prowlarr** (indexers) → **Sonarr** (TV) / **Radarr** (movies)
- **Download client**: qBittorrent and/or SABnzbd, behind the gluetun egress sidecar
- **Jellyfin** (media server) on the GPU tower
- Optional: **Bazarr** (subtitles), **Jellyseerr** (requests), **Recyclarr** (TRaSH config sync), Flaresolverr

## Open questions

- **Torrent vs usenet vs both** → which download client(s), and whether the gluetun sidecar is needed (torrent) or not (pure usenet).
- **Egress VPN provider** — port-forwarding one if ratios matter.
- **v1 scope** — Jellyseerr / Recyclarr / Bazarr in or out of the first cut? (Deferring Bazarr drops one iSCSI PVC.)
- **iSCSI-ZFS liveness** — confirm the storage class provisions and binds before relying on it for Jellyfin/qBittorrent.

## If adopted

Write an ADR for the media-stack storage exception (why media skips foundation stores for NFS, and why the SQLite holdouts get iSCSI block rather than NFS or node disk), stand the stack up in **lab-apps**, and link/remove this doc.
