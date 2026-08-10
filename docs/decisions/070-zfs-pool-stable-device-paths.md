# 070: ZFS Pool Addresses Vdevs by /dev/disk/by-id

**Date:** 2026-08-10
**Status:** accepted
**Related:** [ADR-004](004-zfs-iscsi-for-k8s-storage.md) (ZFS + iSCSI for K8s block storage), [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores)

## Context

The `tank` raidz1 pool on the R730xd was created from bare kernel device names (`/dev/sdg /dev/sdi /dev/sdj`). Kernel names are assigned in enumeration order and are not stable across boots, and ZFS writes whatever path it is given into the on-disk vdev label permanently. On 2026-08-09 a site-wide power cut rebooted the host, enumeration reshuffled, the pool member with serial `WD-WCAZAK023774` moved to `/dev/sdh`, and an ext4 MergerFS bulk disk took over `/dev/sdg`. ZFS opened `/dev/sdg1`, found an ext4 signature where its label should have been, and dropped the member — leaving a three-disk raidz1 running with zero redundancy despite all three disks being healthy.

Recovery was constrained: `zpool online` left the vdev faulted, and `zpool replace` refused (with and without `-f`) because the disk still claimed membership in the imported pool. Only an export and re-import could rebind the vdevs, and that requires the pool fully idle — a platform-wide outage.

## Decision

Build and import the pool using `/dev/disk/by-id/` links, which are derived from durable disk identity rather than enumeration order and therefore survive reboots and controller reordering. The `r730xd-zfs` role resolves each ZFS bay to a by-id path alongside its kernel name and passes those to `zpool create`.

Two link families live under `/dev/disk/by-id` and both are stable: `wwn-*` (World Wide Name) and `ata-<model>_<serial>`. The live pool records `wwn-*` paths, because `zpool import -d /dev/disk/by-id` scans the directory and takes what it finds first; passing individual device files to `-d` to force the `ata-*` form does not work, as `-d` expects a directory to scan for labels. The role generates `ata-*` paths for a fresh `zpool create`, where the path is chosen rather than discovered. The vdev label additionally records the `ata-*` name in its `devid` field regardless, so the mapping from either form to model and serial is always recoverable via `zdb -C`.

Separately, the role's pool-existence guard now detects an **exported** pool, not just an imported one, and refuses to create over existing filesystem signatures unless `zfs_allow_destructive_create` is explicitly set.

## Alternatives Considered

- **`/etc/zfs/vdev_id.conf` with bay-based aliases** — Better failure ergonomics on a 14-bay chassis, since `zpool status` would name the drawer to pull rather than a serial. Rejected for now because it adds a config file that must stay in sync with physical hardware, and the immediate need was to close the outage window with the smallest, most standard change. by-id is the OpenZFS-recommended default.
- **Leaving kernel names and fixing only the dropped member** — Would have restored redundancy without an outage, but leaves the other two vdevs one reshuffle away from the same failure. The pool sits behind every foundation store; recurrence was not acceptable.
- **`zpool labelclear` then `zpool replace`** — Avoids the outage, but only stabilises one vdev, and `labelclear` is destructive with no GUID safety net. Higher risk for a partial fix.

## Consequences

- **Device reshuffle no longer degrades the pool.** by-id links track the physical disk, so power cuts and controller reordering are no longer a storage-integrity event.
- **The creation guard can no longer destroy an intact pool.** `zpool list` only reports imported pools, so the previous guard read "absent" during exactly the maintenance window this ADR describes — and existing signatures auto-escalated the create to `-f`. That path is now a hard failure requiring explicit opt-in.
- **Failure identification requires a lookup.** `zpool status` names a `wwn-*` identifier on the live pool, so replacing a failed disk means mapping that to a physical bay first — via `zdb -C tank`, whose `devid` carries the model and serial, and `phys_path`, whose SCSI id corresponds to the bay. Accepted deliberately; bay aliases via `vdev_id.conf` remain available later if that friction proves real.
- **The underlying power exposure is untouched.** This prevents a reshuffle from degrading the pool, but the rack has no UPS and took six unprotected power cuts in 2.5 weeks (see #212). This ADR addresses a symptom; the power condition is tracked separately.
