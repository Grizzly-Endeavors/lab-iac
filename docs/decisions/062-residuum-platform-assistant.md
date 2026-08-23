# ADR-062: Residuum as the Platform Assistant, on the R730xd with a Stock Image

**Date:** 2026-07-20
**Status:** Accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (stateful workloads live on the R730xd), [ADR-024](024-platform-secrets-on-openbao.md) (OpenBao → Ansible → host secret pattern), [ADR-055](055-s3-object-store-versitygw.md) (the systemd-wrapped compose + ZFS mount-guard role shape this copies)

## Context

We wanted a personal AI agent — [Residuum](https://github.com/Grizzly-Endeavors/residuum), a first-party project — running in the lab to help operate this platform: answer questions about it, watch it, and propose changes. Residuum is a single Rust binary serving a web UI and agent runtime, with all state in one directory.

Two things made the deployment non-obvious. First, residuum shells out to external CLIs (its `exec` tool and MCP stdio servers), resolving them purely against the child process `PATH` — and the published image is a bare `debian-slim` carrying only the binary. Naively, every new CLI the assistant needed would mean rebuilding and maintaining a custom image. Second, an agent that can run shell commands and hold platform credentials needs an explicit, deliberate blast radius.

## Decision

**Run residuum on the R730xd as a Docker Compose service (Ansible role `r730xd-residuum`), using the stock upstream image, reachable only through its outbound relay, and able to change the platform only by opening PRs.**

- **On the R730xd, not in K8s.** It is always-on, it already owns the durable-state tier (ZFS), and a tool whose job is helping operate the cluster should not depend on that cluster being healthy. State lives at `/mnt/zfs/foundation/residuum`, so it rides existing ZFS snapshots.
- **Stock image, never a custom build.** `ghcr.io/grizzly-endeavors/residuum` is pinned by tag and bumped on release, so the deployment tracks upstream directly with no fork to maintain. This constraint was the point, and it drove the two gaps upstream instead of papering over them locally (below).
- **Tools arrive at runtime, not at build time.** A host directory `/opt/residuum-tools` is mounted **read-only** and listed in residuum's `[tools].path`, which prepends it to the PATH of every child process. Adding a CLI is a file drop (Ansible `get_url`, pinned + checksummed); it never requires an image rebuild or even a restart. Read-only means the agent can *use* its toolbox but not rewrite it.
- **Reachable only via the outbound Cloud relay.** The gateway binds loopback in-container and **no ports are published**, so there is no LAN listener and no ingress DNAT rule. This is a security requirement, not a convenience: residuum's web UI has **no local authentication**, so a published port would be an unauthenticated console onto an agent holding platform credentials.
- **Mutation is IaC-only, through pull requests — which the agent may merge itself.** It edits repo files, commits, pushes a branch, and opens a PR, so every change is a reviewable, revertable, durably-recorded diff rather than an untracked mutation. Its org-wide token *can* merge, and Flux reconciles on merge, so **a merge is an apply to the live cluster**. The gate is the IaC pipeline (PR record, CI, Flux reconciliation), not human approval.
- **Models: Ollama Cloud + Google AI Studio.** `glm-5.2:cloud` drives the main agent loop (strong tool use, 1M context); the high-frequency cheap roles (observer, reflector, pulse, subconscious) and embeddings run on Google AI Studio's free tier. Anthropic is deliberately absent: its OAuth tokens are no longer permitted for third-party software.
- **Secrets** follow the established host pattern — OpenBao (`secret/grizzly-platform/platform/residuum`) → Ansible AppRole lookup → `residuum.env` (mode `0600`, `no_log`) → compose `env_file`. Config files carry only `${ENV}` references.

### Two fixes pushed upstream rather than worked around

Holding the "stock image" line surfaced two genuine upstream gaps, both fixed in residuum instead of in a local Dockerfile:

- **[#111](https://github.com/Grizzly-Endeavors/residuum/issues/111) — the `[tools]` PATH mechanism itself.** Without it there was no way to extend the tool PATH at runtime.
- **[#112](https://github.com/Grizzly-Endeavors/residuum/issues/112) — the image shipped no CA trust store and no git.** `reqwest` resolves to rustls + `rustls-platform-verifier`, which on Linux reads the *system* trust store and hard-errors on an empty one (its bundled-roots fallback is `wasm32`-only). Every HTTPS model provider therefore failed TLS. It was easy to miss because the relay kept working — `tokio-tungstenite` uses `rustls-tls-webpki-roots`, which genuinely bundles roots.

## Consequences

- Adding tools is a config change, not a release: the long tail of ops CLIs costs nothing to add, and the deployment still gets upstream fixes automatically.
- **Config is Ansible-owned.** `config.toml`/`providers.toml` are templated onto the state volume; settings changed in residuum's web UI will be reverted on the next playbook run. This is the IaC trade — change them in the role.
- **The assistant can change production unattended.** It can merge its own PR, and Flux applies on merge — so a change can go from ambient trigger (pulse, heartbeat, scheduled action, inbox) to live cluster with no operator present. Every such change is still a PR, so it is visible and revertable after the fact; the recovery story is `git revert` + reconcile, not prevention.
- Because of that reach, **the main model's tool-calling reliability is load-bearing**, not cosmetic. GLM-5.2 has a documented multi-turn tool-argument bug in this project's predecessor ([openclaw#96441](https://github.com/openclaw/openclaw/issues/96441)) on the OpenAI-compat path; residuum uses the native `/api/chat` path, but that must be verified rather than assumed before it runs unattended.
- **No Prometheus metrics.** Residuum exposes OTLP traces but no metrics endpoint; health is the container state plus `gateway listening` / `tunnel connected` in the logs. Tracked as a follow-up.
- Reachability depends on a third-party relay (agent-residuum.com). If it is down, the agent keeps running but the browser path is gone. Acceptable: this is a convenience assistant, not a load-bearing service.
- The relay makes the UI internet-reachable, so **the relay's own authentication is the perimeter** for an agent with platform credentials. That boundary must hold up; it is the single highest-value thing to re-verify.

## Alternatives Considered

- **A thin custom image (`FROM` stock + certs + git + tools).** Rejected: it forks the deployment from upstream, so every image bump becomes manual work — and the CA-certificates gap would have stayed a silent bug for every other self-hoster.
- **Deploy into K8s via Flux.** Rejected: circular dependency (the assistant that helps fix the cluster would live in it), and it wants a durable single directory that the foundation tier already provides.
- **Publish port 7700 on the LAN for direct access.** Rejected: the UI has no authentication of its own.
- **Give the agent direct write credentials** (`kubectl apply`, `bao write`, push straight to default branches). Rejected: not because of the capability level — the agent can already merge — but because routing changes through a PR keeps every mutation recorded, diffable and revertable in version control, per the platform's IaC rule. Direct apply would leave no such trail.
- **Withhold merge rights (propose-only, human merges).** Considered and deliberately not taken: it would make the assistant's usefulness contingent on an operator being present, which defeats running it unattended. The trade is accepted knowingly — see Consequences.
- **Bundled `webpki-roots` instead of system CAs** (an upstream alternative to shipping `ca-certificates`). Not taken: the system trust store is the conventional Linux behaviour and keeps residuum consistent with the host's trust configuration.

## References

- Deploy: `ansible/playbooks/deploy-residuum.yml`, role `ansible/roles/r730xd-residuum/`. Operate: [runbooks/residuum.md](../runbooks/residuum.md).
- Upstream: residuum [#111](https://github.com/Grizzly-Endeavors/residuum/issues/111) (tool PATH), [#112](https://github.com/Grizzly-Endeavors/residuum/issues/112) (CA certs + git), and `docs/systems-usage/tools.md` in that repo.
