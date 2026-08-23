# Scripts

Shell scripts for infrastructure setup. All use `set -euo pipefail` and are idempotent.

Previous K8s cluster scripts are in `archive/pre-migration-2026/scripts/`.

| Script | Purpose |
|--------|---------|
| `bootstrap-ssh-sudo.sh` | Deploy SSH-key auth + passwordless sudo to a new device via one-time password auth |
| `build-jumpbox-image.sh` | Build Debian Trixie image for the jumpbox (AMD C60 mini PC) |
| `build-laptop-iso.sh` | Build preseeded Debian 13 ISO for laptops |
| `build-r730xd-iso.sh` | Build preseeded Debian 13 ISO for R730xd automated install |
| `build-worker-iso.sh` | Build preseeded Debian 13 ISO for K8s worker nodes |
| `configure-r730xd-jbod.sh` | Configure R730xd PERC H730 controller for JBOD mode via iDRAC racadm |
| `derive-op-tokens.sh` | Derive this control node's 1Password service-account tokens from the encrypted Ansible vault |
| `fetch-openbao-ca.sh` | Pull the current OpenBao CA from r730xd into the committed ConfigMap + local trust store |
| `install-k8s-cli.sh` | Install Cilium/Hubble CLI tools for cluster debugging |
| `metabase-add-database.sh` | Register a Metabase data source from 1Password credentials, using the read-only `metabase_ro` account |
| `migrate-secrets-to-1password.sh` | Copy every OpenBao KV secret into the 1Password `grizzly-platform` vault and verify each field byte-for-byte |
| `install-observability-cli.sh` | Install logcli/promtool/amtool + Fish env vars for the observability stack |
| `query-r730xd-bays.sh` | Query R730xd drive bay info via iDRAC racadm (JSON, consumed by Ansible) |
| `set-openbao-approle-secrets.sh` | Upsert the ansible-iac AppRole role_id/secret_id into the encrypted vault |
| `set-openbao-bootstrap-secrets.sh` | Upsert the Infisical universal-auth credentials OpenBao's auto-unseal service needs |
| `wipe-r730xd-bays.sh` | Wipe RAID/filesystem/partition signatures from R730xd drive bays before storage-prep |
