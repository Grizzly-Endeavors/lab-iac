# Tools — infra interaction reference

A map of what's available for investigating and operating grizzly-platform, so a session doesn't have to re-derive it from scratch. Covers this control node (jumpbox) and every remote host/interface reachable from it.

**Keep this current.** When you install something new, find a tool already present that isn't listed, or a host/access path changes (new SSH target, a service moves, a CLI gets swapped), update this file as part of that work — not as a separate cleanup pass later. Stale terrain maps are worse than none.

## Local — this control node

Everything below is on `PATH` here. No "why" column — check the relevant runbook/ADR via `INDEX.md` for that; this is just what's callable.

**VCS / GitHub:** `git`, `gh`

**Containers:** `docker`, `docker compose`

**Kubernetes:** `kubectl`, `helm`, `flux`, `k9s`, `cilium`, `hubble`, `argo`
- `kubectl kustomize` covers standalone kustomize — no separate `kustomize` binary.

**Secrets:** `op` (1Password CLI — the only secrets path). Authenticates via `OP_SERVICE_ACCOUNT_TOKEN`; three tokens are cached at `~/.config/op-tokens/{eso-reader,ansible-reader,operator}` and re-derivable with `scripts/derive-op-tokens.sh`. Read with `op read op://grizzly-platform/<item>/<field>`; only the `operator` token can write. See `docs/runbooks/onepassword-quickref.md`.

**IaC / linting:** `ansible`, `ansible-playbook`, `ansible-vault`, `ansible-lint`, `pre-commit`, `shellcheck`, `yamllint`
- Ansible collections: `community.crypto`, `community.general`, `community.aws`, `community.dns`, `community.docker`, `kubernetes.core`, `ansible.posix` — see `ansible/requirements.yml` for version floors.

**Data/text:** `yq` (mikefarah), `jq`, `envsubst`

**Foundation stores:** `psql` (foundation Postgres is LAN-exposed at `10.0.0.200`, reachable directly from here), `mc` (MinIO client — versitygw S3 CLI), `valkey-cli` (kv-cache, same LAN-exposed pattern), `aws`-cli v2 (`aws s3api` object-lock/versioning/retention calls against versitygw that `mc` doesn't cover — `docs/runbooks/versitygw-cli.md`)

**Observability:** `logcli`, `promtool`, `amtool` — Fish env vars set: `LOKI_ADDR=http://10.0.0.200:3100`, `ALERTMANAGER_URL=http://10.0.0.200:9093`. `promtool` takes `--url`/positional target per-invocation (Prometheus at `10.0.0.200:9090`), no env var.

**Networking:** `wg` (wireguard-tools — inspect the VPS↔R730xd tunnel), `nmap`, `dig`, `nslookup`, `sshpass` (used for one-shot iDRAC racadm calls)

**Signing:** `cosign` — key rotation / manual `cosign verify` for the CI gate signing flow (`docs/runbooks/ci-gate.md`, ADR-028). Installed as a pinned release binary (not via apt/go, since no `go` toolchain here) — re-check https://github.com/sigstore/cosign/releases when it needs bumping.

**Misc:** `netbird` (mesh client, present but this node's role in it is operator access, not a managed workload), `gpg`, `openssl`, `terraform` (installed but unused — evaluated and rejected for Authentik config in ADR-037, keep around only if something else needs it)

**grizzly-gate:** CLI binary exists at `~/.claude/plugins/cache/grizzly-endeavors/grizzly-gate/*/bin/grizzly-gate` (not on PATH), but the real interface here is the MCP tools — `mcp__plugin_grizzly-gate_gate__run_gate`, `get_check_output`, `get_report_summary`, `list_honest_map_violations`. Use those, not the raw binary.

## Remote hosts

Nothing below runs locally — reach it over SSH or through Kubernetes/Docker exec. IPs are the plaintext source of truth in `ansible/inventory/group_vars/all/network.yml` (already public — this repo has no PII/secrets in git; see `.claude` memory).

### r730xd (`10.0.0.200`) — `ssh bearf@10.0.0.200`
Storage backbone + foundation stores + observability host.
- **Storage:** `zfs`, `zpool` (raidz1 pool — hot tier), `mergerfs` + `snapraid` (bulk tier), `smartctl`
- **System:** `docker` / `docker compose` (all foundation-store and observability containers run here), `iptables` (VPS tunnel DNAT), `ipmitool`
- **In-container access** (via `docker exec`):
  - `docker exec foundation-postgres psql -U postgres` (or reach directly from this node — see Local)
  - `docker exec foundation-kv-cache valkey-cli -a <password> ping`
  - `docker exec foundation-s3-hot <versitygw admin commands>` — see `docs/runbooks/versitygw-cli.md`

### iDRAC on r730xd (`10.0.0.203`) — `sshpass -p $IDRAC_PASSWORD ssh root@10.0.0.203`
Out-of-band BMC. `racadm` is the only surface (storage/bay queries, power actions). No Enterprise license — no virtual media. Password in 1Password (`platform-idrac`), not this repo.

### proxy-vps (Hetzner, port 2222) — `ssh -p 2222 bearf@<proxy_vps_public_ip>` (or `ssh proxy-vps` per `~/.ssh/config`)
Public ingress edge. Caddy (reverse proxy + wildcard TLS), UFW, HAProxy (mail L4 ingress).

### K8s cluster nodes — `ssh bearf@<node_ip>` (see `ansible/inventory/lab-nodes.yml`)
`dell-inspiron-15` (control plane, `10.0.0.226`), `quanta` (`10.0.0.202`, BMC `10.0.0.201`), `intel-nuc` (`10.0.0.46`), `optiplex` (`10.0.0.187`). Standard kubeadm/containerd node tooling; day-to-day interaction goes through `kubectl` from this node instead of SSH-ing in.

### Authentik — `kubectl -n authentik exec deploy/authentik-server -- ak shell -c "..."`
`ak` is Authentik's Django management CLI, only reachable inside the pod. Used for anything outside the blueprint config-as-code path: minting/rotating service-account API tokens, one-off data fixes. See `docs/runbooks/invite-authentik-reader.md` for the pattern (`ak shell -c` with inline Python, or `ak apply_blueprint`). Routine config still goes through blueprints (`kubernetes/infrastructure/authentik/blueprints/`), not `ak` — this is the escape hatch, not the primary path.

### Aerohive SR2024 switch (`10.0.0.153`) — legacy SSH, `admin`/`aerohive`
HiveOS CLI. Standalone mode (no controller). Can wedge on PoE (`pse`) — power-pull is the only recovery. See `docs/aerohive-cli-reference.md` and `.claude` memory.

### Digi EX50 router
DAL Admin CLI over SSH (IPv6 link-local for bench access, LAN IP `10.0.0.1` post-cutover) or the identical surface over serial (RJ45, RS-232, needs the correct — non-rollover — pinout). See `docs/runbooks/ex50-console-access.md` and `docs/ex50-dal-interface.md`.

## Verifying the local list

```fish
for t in git gh docker kubectl helm flux k9s cilium hubble argo op ansible ansible-lint pre-commit shellcheck yamllint yq jq envsubst psql mc logcli promtool amtool wg nmap dig nslookup sshpass netbird gpg openssl terraform cosign aws valkey-cli
    if command -v $t >/dev/null
        echo "OK   $t"
    else
        echo "MISS $t"
    end
end
```
