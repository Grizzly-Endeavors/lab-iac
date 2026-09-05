# ADR-072: Immich on the Foundation Stores, with Vector Extensions Added to the Shared Postgres

**Date:** 2026-09-05
**Status:** Accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-025](025-personal-apps-in-separate-repo.md) (personal apps in lab-apps), [ADR-033](033-central-identity-authentik.md) (Authentik), [ADR-037](037-authentik-config-as-code-blueprints.md) (blueprints), [ADR-038](038-nextcloud-on-foundation-stores-and-sso.md) (the per-app role+DB pattern), [ADR-055](055-s3-object-store-versitygw.md) (versitygw), [ADR-056](056-redis-to-valkey.md) (kv-cache)

## Context

Immich is a self-hosted photo and video library — the personal-app class ADR-025 already names it in. Standing it up ran into one thing the platform had never been asked for: Immich's smart search and facial recognition are built on pgvector plus VectorChord, and the foundation PostgreSQL runs a stock `postgres:16` image that has neither. It has `cube`, `earthdistance`, `pg_trgm` and `unaccent`; it does not have `vector` or `vchord`, and VectorChord additionally has to be in `shared_preload_libraries` before `CREATE EXTENSION` will work at all.

That makes Immich the first workload whose database needs something the shared instance does not ship, which forces a question the platform had not had to answer: does a foundation store grow to meet an app, or does an app that needs more get its own store?

Immich also pushes on the storage rule from the other direction. Its media library cannot go on the foundation S3 gateways: object storage is unimplemented upstream, tracked in a discussion open since 2023, and as of April 2026 maintainers describe the prerequisite refactors — consolidating filesystem calls, reworking the job system, finishing the `asset_file` migration — as a "long term endeavour." They also explicitly advise against pointing `UPLOAD_LOCATION` at a FUSE/rclone mount of a bucket, because Immich relies on hard and soft links that S3-backed mounts cannot provide.

And Immich expects PostgreSQL superuser by default, which it uses to install and upgrade its own extensions. On a dedicated database that is unremarkable. On this one it is not: the foundation Postgres holds fourteen databases including Authentik, Stalwart, Nextcloud, Langfuse and the gameservers product event log.

## Decision

**The extensions are added to the foundation PostgreSQL, not worked around.** `ansible/roles/r730xd-postgres/files/Dockerfile` builds the foundation image as stock `postgres:16` plus `postgresql-16-pgvector` from PGDG and the VectorChord `.deb`, and the role adds `vchord.so` to `shared_preload_libraries`. Both versions are pinned in the role's defaults and the image tag encodes all three, so a bump produces a distinct image rather than silently reusing a stale one.

The alternative — a second Postgres for the one app that needs more — would have split the store the whole ADR-003 design exists to consolidate, and split it on a boundary ("apps that want vector search") that will only get blurrier. Extensions are per-database and opt-in: the other thirteen databases gain nothing and notice nothing. The cost is that the foundation image is now ours to rebuild rather than a tag we pull, which is a small, well-understood maintenance surface for keeping one database instead of two.

**The image is built on the R730xd, not pulled from the in-cluster registry.** The foundation stores must be able to come up without the cluster, and the Zot registry sits downstream of them.

**Immich gets a plain non-superuser role that owns its own database, like every other app**, and the provisioning play creates `vector`, `vchord`, `cube` and `earthdistance` inside the `immich` database as `postgres`. Granting Immich superuser on this instance would give a photo app read and write over every other app's data and the ability to write files as the `postgres` user — trading the isolation invariant the shared store rests on for the convenience of one app managing its own extension lifecycle. The accepted cost is that an Immich release which widens its required extension range needs the pins bumped and an `ALTER EXTENSION ... UPDATE` added to the play, rather than Immich doing it unattended.

**Immich's own database backup stays off.** It shells out to `pg_dumpall`, which needs superuser. The foundation Postgres already runs a nightly `pg_dumpall` covering every database including `immich`, so enabling it would add a job that can only fail.

**The photo library is an RWX NFS PVC on the MergerFS pool** — the ADR-003 carve-out for workloads that need a POSIX tree rather than SQL, KV or S3, and the same reasoning the servarr exploration reached for media. It is still foundation-provided storage reached over the LAN; no application state touches a node disk. The ML model cache is a small iSCSI-ZFS block volume, and is a cache rather than durable state — the models re-download.

**Authentik is the IdP over OIDC**, with a provider registered by `blueprints/immich.yaml` at `photos.grizzly-endeavors.com`. Three redirect URIs are registered, including the `app.immich:///oauth-callback` deep link the mobile apps require. An `immich_role` scope mapping returns `admin` for `grizzly-admins` members and `user` otherwise, so Immich administrator follows group membership rather than being pinned to a person. Local password login stays enabled as break-glass, matching Nextcloud.

**Immich's settings live in a config file in git, not in its database.** `IMMICH_CONFIG_FILE` makes a mounted YAML file the source of truth for what the admin Settings panel would otherwise hold, which is what makes the OIDC wiring and the theme reproducible across a rebuild instead of being undocumented clicks. The OAuth client secret is the one value that cannot be in git, so an initContainer substitutes it — and the client id — into the file at pod start from the ESO-synced Secret. Substitution is a literal `sed` replace rather than a template engine because the config legitimately contains brace syntax of its own.

**The theme is Immich's `theme.customCss`, driving Immich's CSS custom properties** with the same palette the Authentik brand blueprint uses. Overriding the handful of `--immich-*` colour tokens is the upgrade-safe lever, for the same reason the Authentik CSS overrides PatternFly custom properties rather than component class names.

## Consequences

- **The foundation Postgres image is now built, not pulled.** A base-image bump means editing the role's pins and re-running the play, and the play rebuilds only when the Dockerfile or the pinned versions change. A PGDG pin that upstream has since dropped fails the build loudly, which is intended — a shared database should not drift its extension versions on a rebuild.
- **Adding `shared_preload_libraries` is an instance-wide change.** If `vchord.so` ever fails to load, PostgreSQL does not start, and that is every app, not just Immich. The library is verified in a throwaway container before the live container is swapped, and the setting is the first thing to check if the foundation Postgres refuses to start after an image change.
- **The extension lifecycle is a manual step on some Immich upgrades.** Immich checks the installed versions at startup and refuses to run if one is out of its accepted range. That failure is loud and appears in the server log, but it will not fix itself the way it would with superuser.
- **Storage-usage figures in Immich's UI reflect the NFS mount, so they report the whole MergerFS pool**, not an Immich-specific quota. The PVC's declared size is a ceiling on paper only; real capacity is the pool's and is monitored on the R730xd.
- **Machine learning is CPU-only** — no node in the fleet has a usable GPU. Smart search and face detection work, just slowly on a first bulk import. If a GPU host lands later, the ML deployment is the piece that moves.
- **The admin Settings panel is expected to become read-only** with a config file in play. Tuning a job concurrency or an ffmpeg preset becomes a PR rather than a toggle, which is the intended trade for having those settings in git.
- One more OIDC client on Authentik, and one more `stores-<app>` item in 1Password.

## Alternatives Considered

- **A second, Immich-specific Postgres on the R730xd** (its own container, upstream's `ghcr.io/immich-app/postgres` image). Zero blast radius on the shared instance and Immich manages its own extensions with superuser on a database that is entirely its own. **Rejected** because it splits the foundation store on a boundary that will keep moving — the next app wanting vector search would face the same question — and doubles the backup, monitoring and upgrade story to avoid a change that is additive and opt-in per database.
- **Adopting upstream's Postgres image as the foundation image.** It bundles exactly the right extension versions and is maintained by people who care about them. **Rejected** because it makes the whole platform's database inherit the release cadence and priorities of one personal app.
- **An in-cluster Postgres for Immich (CloudNativePG + `tensorchord/cloudnative-vectorchord`)**, which is what the community Helm chart assumes. **Rejected** on ADR-003: durable state does not go on cluster storage, and this would introduce a second database operator to run.
- **Granting the `immich` role superuser.** Upstream's default path; makes extension upgrades unattended and Immich's own backup work. **Rejected** — see the decision above. The isolation invariant is worth more than the convenience, especially with a nightly dump already covering the database.
- **The community Helm chart (`immich-0.13.1`).** **Rejected**: its own README says it is not version-synced with Immich releases, so the image tag is hand-managed either way, and with its bundled Postgres and Redis disabled in favour of the foundation stores it would wrap three Deployments and two Services in an indirection that is a second version axis to track. Same reasoning as ADR-065 for Metabase.
- **Leaving settings in Immich's database and configuring OIDC and the theme through the admin UI.** Simpler day-to-day and keeps every knob live-tweakable. **Rejected** because the two things specifically being set up here — SSO and branding — would then exist only as unversioned rows that a rebuild loses.

## References

- `ansible/roles/r730xd-postgres/` — the foundation image, its pins, and the preload setting.
- `ansible/playbooks/setup-immich-stores.yml` — role, database and extension provisioning.
- `kubernetes/infrastructure/authentik/blueprints/immich.yaml` — the OIDC provider, role mapping and application.
- `Grizzly-Endeavors/lab-apps` `apps/immich/` — the workload manifests.
- [Immich: running against a standalone Postgres](https://docs.immich.app/administration/postgres-standalone) — the extension requirements and the non-superuser caveat.
- [Immich discussion #23745](https://github.com/immich-app/immich/discussions/23745) — the open object-storage thread behind the NFS decision.
