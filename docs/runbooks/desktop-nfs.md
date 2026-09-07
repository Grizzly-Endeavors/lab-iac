# Desktop NFS share

The control workstation mounts the R730xd foundation pool at `/mnt/pool`. The server export is managed by `r730xd-nfs-server`; the workstation's `/etc/fstab` entry is managed by `ansible/playbooks/setup-desktop-nfs.yml`. Systemd mounts the share when a program first accesses it, so access can recover after the network becomes available. `nofail` allows the workstation to boot when the storage server is unavailable.

Apply from the repository root:

```sh
ansible-playbook -i localhost, -c local ansible/playbooks/setup-desktop-nfs.yml
```

Applying changed mount options briefly unmounts the share. Close programs using `/mnt/pool` first. The playbook fails visibly if the share cannot be unmounted or the `Scratch` directory cannot be reached.

## Health and recovery

Run `ls /mnt/pool/Scratch`, then `findmnt -t nfs,nfs4 /mnt/pool` to verify the real NFS mount. `systemctl status mnt-pool.automount mnt-pool.mount` shows the local units; `sudo journalctl -u mnt-pool.mount` shows connection errors. If mounting fails, check the workstation's LAN route to the R730xd and the server's `nfs-server` service, then retry access. The existing `monitoring-checks` role checks NFS server availability; the workstation automount has no separate alert.

Photography backups are under `/mnt/pool/Scratch/Bear/Photos`; the phone camera backup is under `/mnt/pool/Scratch/Bear/Phone Backup 2025/DCIM/Camera`. Import through the Immich upload API, keeping the NFS source files intact. App data under the same pool is independent of these desktop archives.
