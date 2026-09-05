# Integration guides — how to consume the platform

Consumer-facing guides. Each answers one question: **"I'm building or deploying an app — how do I leverage this platform service?"** They are the front door for a *consumer* of a subsystem, not an operator of it.

Three doc families, three jobs — reach for the right one:

- **Integration guide** (here, `docs/integration/`) — *how to consume it.* You have an app and you want a database, a bucket, SSO, a secret in your namespace, mail, telemetry, or a deploy slot. Task-oriented, copy-paste, ends at "your app is wired and verified."
- **Runbook** (`docs/runbooks/`) — *how to operate it.* You need to deploy, drive, rotate, or recover the running service itself.
- **ADR** (`docs/decisions/`) — *why it's built this way.* The decision and its trade-offs.

An integration guide owns the consumer walkthrough and *links* to the runbook and ADR rather than repeating them. If you find yourself explaining how to rotate an unseal key or tune `shared_buffers` in here, that content belongs in the runbook.

See [`INDEX.md`](INDEX.md) for the full list. When you add a consumable capability to the platform, add an integration guide here and a line to the index.

## The shared shape

Every guide follows the same skeleton so a consumer knows where to look:

1. **What you get** — the resource and its endpoint, in one line.
2. **When to use it** (and when not) — vs. the alternatives.
3. **Prerequisites** — what must already exist.
4. **Provision** — the foundation-side step (usually an Ansible `setup-<app>-stores.yml` play or a 1Password write) that mints the resource + credential.
5. **Wire it up** — the consumer-side manifest/config, with real hostnames, paths, and a copy-paste example.
6. **Verify** — how to confirm it works end-to-end.
7. **Troubleshoot** — the failure modes you'll actually hit.
8. **See also** — the runbook and ADR that own the operator and decision stories.

## The one rule that ties them together

Durable app state lives on the **R730xd foundation stores** (`10.0.0.200`), never on K8s node disks — Postgres, Valkey (kv-cache), and versitygw S3. App **credentials** live in **1Password** and reach your workload through **External Secrets**. So most guides here are two moves: run a provisioning play on the R730xd that mints a scoped resource + writes its credential to 1Password, then declare an `ExternalSecret` that lands that credential in your namespace. Learn that pattern once (see [secrets.md](secrets.md)) and every store guide is a variation on it.
