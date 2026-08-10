# Runbook: taking the ZFS pool offline

How to quiesce everything that touches `tank` on the R730xd so the pool can be exported, and how to bring it all back. Needed for any operation requiring an idle pool — export/import, vdev path changes, controller work.

**This is a platform-wide outage.** `tank` backs foundation Postgres, kv-cache, ClickHouse, s3-hot, OpenBao, Residuum, the entire observability stack, and 35 zvols serving K8s PVCs. Authentik depends on Postgres and kv-cache, so **SSO goes down** — confirm `kubectl` and host SSH work without it before starting.

Related: [ADR-070](../decisions/070-zfs-pool-stable-device-paths.md) (stable device paths), [ADR-003](../decisions/003-foundation-stores-on-r730xd.md) (foundation stores).

## Before you start

Take a recursive snapshot and send it to the bulk tier. The snapshot is atomic and instantaneous, and `zfs send` reads the frozen snapshot — so services can keep running during the send with no loss of backup fidelity.

```bash
sudo zfs snapshot -r tank@<label>
sudo bash -c "/usr/sbin/zfs send -R tank@<label> | zstd -T0 -3 -o /mnt/pool/backups/tank-<label>.zfs.zst"
sudo bash -c "zstd -dc /mnt/pool/backups/tank-<label>.zfs.zst | /usr/sbin/zstream dump" | tail -5
```

`zstream` and `zstreamdump` live in `/usr/sbin` and are not on the default SSH `PATH` — call them by absolute path. Expect the send to be slow if the pool is degraded: every read is reconstructed from parity.

Take a logical Postgres dump too. It restores without any ZFS tooling, which is the right fallback if a stream ever proves unusable:

```bash
sudo bash -c "docker exec foundation-postgres pg_dumpall -U postgres | gzip > /mnt/pool/backups/postgres/pg_dumpall-<label>.sql.gz"
```

Avoid the cron windows: `02:00` daily (pg-backup), `02:15` daily (openbao-backup), `02:00` Sunday (scrub).

## Stop

**1. Suspend Flux.** All kustomizations reconcile on a 5-minute interval, so anything scaled to zero comes straight back otherwise.

```bash
flux suspend kustomization --all -n flux-system
```

**2. Quiesce anything that creates PVCs**, or it will provision new zvols mid-window:

```bash
kubectl -n argo scale deploy/argo-argo-workflows-workflow-controller --replicas=0
kubectl -n game-servers scale deploy/grizzly-gameservers-bot --replicas=0
kubectl -n actual-budget patch cronjob/actual-budget-backup -p '{"spec":{"suspend":true}}'
```

**3. Scale down the tank-PVC consumers** and wait for pods to fully terminate — that is what triggers CSI `NodeUnstageVolume` and the initiator logout:

```bash
kubectl -n nextcloud     scale deploy/nextcloud     --replicas=0
kubectl -n ntfy          scale deploy/ntfy          --replicas=0
kubectl -n resume-site   scale deploy/resume-site   --replicas=0
kubectl -n registry      scale deploy/registry      --replicas=0
kubectl -n actual-budget scale deploy/actual-budget --replicas=0
```

**Gate:** on the R730xd, `ss -tn | grep :3260` must return nothing. Do not continue while sessions remain.

**4. Scale down the CSI control plane** — controller first. The node DaemonSet must outlive step 3 to perform the logouts:

```bash
kubectl -n democratic-csi scale deploy/democratic-csi-iscsi-controller --replicas=0
kubectl -n democratic-csi patch ds/democratic-csi-iscsi-node -p '{"spec":{"template":{"spec":{"nodeSelector":{"maintenance":"drained"}}}}}'
```

Leave the `nfs-controller` / `nfs-node` alone — they serve MergerFS, not `tank`.

**5. Stop tank-backed Docker on the host.** Observability first (it depends on foundation), then foundation. Use `compose down` / `systemctl stop`, never bare `docker stop` — everything is `restart: unless-stopped` and a plain stop will not survive a daemon restart.

```bash
for s in alloy grafana tempo loki prometheus exporters openbao-agent; do
  sudo docker compose -f /opt/observability/$s/docker-compose.yml down
done
sudo systemctl stop foundation-residuum
for s in clickhouse kv-cache postgres; do
  sudo docker compose -f /opt/foundation/$s/docker-compose.yml down
done
sudo systemctl stop foundation-s3-hot
sudo systemctl stop openbao-auto-unseal foundation-openbao
```

Leave `foundation-s3-bulk` and `nfs-server` running — both are MergerFS-backed.

**6. Save and stop the iSCSI target.** `rtslib-fb-targetctl` is what pins the 35 zvols; the export fails with "pool is busy" until it is down.

```bash
sudo targetctl save                              # rebuilds all 35 LUNs on restore
sudo systemctl stop rtslib-fb-targetctl.service  # ExecStop runs `targetctl clear`
ls /sys/kernel/config/target/core/               # no iblock_* should remain
```

**7. Confirm idle, then export:**

```bash
sudo lsof +D /mnt/zfs
sudo zpool export tank
```

## Start

Reverse order. Each step gates the next.

**1. Import, and do not proceed until the zvol links exist** — `targetctl restore` fails on missing backing devices:

```bash
sudo zpool import -d /dev/disk/by-id tank
zfs mount | wc -l                        # expect 11 filesystems
ls /dev/zvol/tank/iscsi/ | wc -l         # expect 35
```

Always import with `-d /dev/disk/by-id` so vdev paths stay stable — see [ADR-070](../decisions/070-zfs-pool-stable-device-paths.md).

If a vdev rejoins after being offline, ZFS delta-resilvers the transactions it missed. **Let the resilver finish before restarting services** — it runs faster without competing I/O.

**2. iSCSI target:** `sudo systemctl start rtslib-fb-targetctl.service`, then `sudo targetcli ls` → 35 backstores, 35 targets.

**3. OpenBao, early** — External Secrets and the Prometheus agent both depend on it:

```bash
sudo systemctl start foundation-openbao
sudo systemctl start openbao-auto-unseal
```

`openbao-auto-unseal` is `Restart=no` and needs Infisical reachable. If it fails, fix the cause and re-run it manually; OpenBao stays sealed until then.

**4. Foundation stores, in order:** `postgres` → `kv-cache` → `clickhouse` → `systemctl start foundation-s3-hot`.

**5. Observability, in order:** `prometheus` → `exporters` → `loki` → `tempo` → `grafana` → `alloy` → `openbao-agent`.

Grafana's database is foundation Postgres, and Loki and Tempo use s3-hot as their object store — starting either ahead of its dependency produces a crash loop.

**6. Residuum:** `sudo systemctl start foundation-residuum`.

**7. CSI, node before controller:**

```bash
kubectl -n democratic-csi patch ds/democratic-csi-iscsi-node --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/maintenance"}]'
# wait for all node pods Ready, then:
kubectl -n democratic-csi scale deploy/democratic-csi-iscsi-controller --replicas=1
```

**8. Resume Flux**, which restores the application Deployments to their declared replicas:

```bash
flux resume kustomization --all -n flux-system
```

Then un-suspend the `actual-budget-backup` CronJob.

## Verify

- `zpool status tank` → `ONLINE`, members named by `ata-*` id, `errors: No known data errors`
- `zdb -C tank` → `path:` fields are by-id strings (this is what boot consumes, via `zpool.cache`)
- `ss -tn | grep :3260` on the host → the live initiators reconnected
- Each restored PVC is writable — exec into the pod and write a file; a Running pod is not proof
- Authentik login works (proves Postgres + kv-cache end to end)
- Grafana loads, Prometheus scrape continuity intact, Loki/Tempo flushing to s3-hot without errors

## If the import fails

Labels on all members are the thing to check first — `zdb -l /dev/disk/by-id/<link>-part1` on each. A pool whose members all carry valid, matching `pool_guid` and `top_guid` values should import.

- Import by GUID if the name is ambiguous: `zpool import <pool_guid>`
- To restore service on the old paths and reassess: `zpool import -d /dev -f tank`
- Export/import does not rewrite user data, so there is no destructive point of no return in this procedure

The genuinely destructive risk nearby is `zpool create -f`. The `r730xd-zfs` role will refuse to create over existing signatures unless `zfs_allow_destructive_create=true` is passed — do not pass it to work around an import problem.
