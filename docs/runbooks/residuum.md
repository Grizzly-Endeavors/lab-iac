# Runbook: Residuum personal agent

Residuum is the platform assistant running on the **R730xd** (`10.0.0.200`) as a Docker Compose service managed by systemd. Design rationale: [ADR-062](../decisions/062-residuum-platform-assistant.md).

| | |
|---|---|
| Host | R730xd (`10.0.0.200`) |
| Unit | `foundation-residuum.service` |
| Container | `foundation-residuum` |
| Compose dir | `/opt/residuum` |
| State | `/mnt/zfs/foundation/residuum` (config, workspace, memory, vectors, secret store) |
| Tools | `/opt/residuum-tools` (mounted read-only) |
| Image | `ghcr.io/grizzly-endeavors/residuum` (stock upstream, pinned) |
| Access | Browser via the Cloud relay only — **no published port** |

## Deploy / update

```bash
ansible-playbook -i ansible/inventory ansible/playbooks/deploy-residuum.yml
# tools volume only:
ansible-playbook -i ansible/inventory ansible/playbooks/deploy-residuum.yml --tags tools
```

**Upgrading residuum:** bump `residuum_image` in `ansible/roles/r730xd-residuum/defaults/main.yml` to the new release tag and re-run. There is no custom image — the tag is the only thing that changes.

## Health

There is no HTTP probe from the host: the gateway binds loopback *inside* the container and nothing is published. Health is read from container state + logs.

```bash
ssh bearf@10.0.0.200
systemctl status foundation-residuum
docker ps --filter name=foundation-residuum
docker logs --tail 100 foundation-residuum
```

Two log lines are the signal:

- `gateway listening` — config loaded successfully (it did **not** fall into the setup wizard).
- `tunnel connected` — the relay is up, so the agent is reachable from a browser.

## Adding a CLI tool (no rebuild, no restart)

The agent's PATH is extended from `/opt/residuum-tools` (read-only mount) via residuum's `[tools].path`. **Only single-file static binaries** work this way — `git` and `ca-certificates` ship in the image itself; `node`/`python` cannot be added here.

Preferred (IaC): add an entry to `residuum_tool_archives` (or a `get_url` task) in the role with a pinned version + sha256, then re-run with `--tags tools`.

The `exec` tool re-reads the effective PATH on every call, so a new binary is usable immediately. Only an **already-running MCP stdio server** keeps its old PATH, until it next reconnects.

Pin versions to the platform, not to "latest": `kubectl` must stay within ±1 minor of the cluster API server, and `flux` should match the deployed source-controller.

## Common failures

**Container restart-loops immediately after deploy.**
Almost always config. Check `docker logs foundation-residuum`:
- `timezone is required` → `RESIDUUM_TIMEZONE` missing from `residuum.env`; residuum refuses to boot and would otherwise open the interactive setup wizard.
- TLS / certificate errors reaching a model provider → the image is missing its CA bundle. Confirm the pinned image is ≥ the release carrying residuum [#112](https://github.com/Grizzly-Endeavors/residuum/issues/112).

**Agent runs but the browser can't reach it.**
Check for `tunnel connected`. If absent, the relay token is bad or the relay is down (`RESIDUUM_CLOUD_TOKEN`, from the 1Password item `platform-residuum`). The agent keeps working locally; only the browser path is lost. There is intentionally **no** LAN fallback — see below.

**Agent can't run a tool.**
`docker exec foundation-residuum sh -c 'echo $PATH; which gh kubectl flux bao uv'`. If the mount is missing, check `/opt/residuum-tools` exists on the host and the compose volume line is present.

**Agent says it "can't access GitHub" / can't push.**
Check git's credential helper *before* suspecting the token — `gh` and `git` authenticate differently, and `GH_TOKEN` only covers `gh`. Git never reads it, so a broken helper degrades to "public repos read fine, everything else fails":

```bash
docker exec foundation-residuum sh -c 'gh auth status'                  # gh path
docker exec foundation-residuum sh -c 'git config --get credential.https://github.com.helper'
docker exec foundation-residuum sh -c 'printf "protocol=https\nhost=github.com\n\n" | git credential fill | grep "^username="'
```

The last command must print `username=x-access-token`. If the helper is empty, `GIT_CONFIG_GLOBAL` isn't set or `/mnt/zfs/foundation/residuum/gitconfig` is missing — re-run the playbook. Note the gitconfig **must** live on the state volume: only `/home/residuum/.residuum` is persistent; a `~/.gitconfig` sits on the container's ephemeral overlay and disappears on recreation.

**Agent can't merge a PR.**
The token is org-wide and can merge, so a merge failure is a real fault (or branch protection), not expected behaviour.

**Backing out a change the agent made.** Every mutation is a merged PR, so recovery is `git revert` on the merge commit, push, and let Flux reconcile — check `flux get kustomizations` afterwards. Find recent agent activity with `gh pr list --author <agent-account> --state merged`.

**Settings changed in the web UI reverted.**
Expected. `config.toml` and `providers.toml` are Ansible-owned; the next playbook run re-templates them. Change them in `ansible/roles/r730xd-residuum/` instead.

## Restart / recover

```bash
systemctl restart foundation-residuum     # correct way — do NOT `docker compose down` directly
```

The unit guards on the ZFS mount (`RequiresMountsFor`), so it refuses to start onto a missing `/mnt/zfs` rather than bootstrapping a blank workspace over the real one. If it won't start, check the mount first: `findmnt /mnt/zfs`.

**Rebuild from scratch:** state is entirely `/mnt/zfs/foundation/residuum`. Restore that directory from a ZFS snapshot and re-run the playbook. Nothing else is stateful.

## Security notes

- The web UI has **no local authentication**. The only protections are (a) loopback bind + no published port, and (b) the relay's own auth. **Never add a `ports:` mapping** to the compose file — that would expose an unauthenticated console onto an agent holding platform credentials.
- The tools volume is mounted read-only so the agent cannot rewrite its own toolbox. It *can* still write to `~/.residuum/bin` on the state volume.
- Mutation goes through PRs, but the agent can merge its own and Flux applies on merge — it can change production unattended. The safety property is *traceability*, not prevention: every change is a PR you can find and revert. See "Backing out a change the agent made" above.
- Rotating a credential: update the 1Password item, then re-run the playbook (re-renders `residuum.env`) and restart.
