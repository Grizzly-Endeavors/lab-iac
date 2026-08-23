# grizzly-platform

Self-hosted infrastructure for Grizzly Endeavors projects (Infrastructure as Code). See `README.md` for architecture, machines, repo structure, and common commands.

**Finding things: start from `INDEX.md` (repo root) — the navigation map.** It points to each subsystem's decisions (*why*, ADRs in `docs/decisions/`), runbooks (*how to operate*, `docs/runbooks/`), and code — so subsystem detail (the CI gate, secrets, mail, storage, identity, …) is retrieved when you work on it rather than carried here. `docs/hardware.md` has the live machine inventory, `docs/network.md` the network topology. **Active multi-phase work lives in `docs/in-progress/`** — when the user references something as in-flight or asks you to pick up a prior thread, check there first. The completed 2026 migration record is in `archive/migration-2026/`. **`TOOLS.md` (repo root) is the terrain map of what's callable from the control node and how to reach every remote host/BMC/service** — check it before assuming a CLI or access path doesn't exist.

# Rules

- **Read-only SSH to any host in this repo's inventory is always allowed without asking first** — this includes BMCs/iDRACs (e.g. `racadm get`/`storage get` diagnostics), switches, and cluster nodes. Status checks, log reads, and other non-mutating commands don't need per-host sign-off. Mutating actions (config changes, resets, power actions, writes) still follow the standard destructive-action confirmation rules.
- All configuration and infrastructure MUST be conducted with IaC. Manual changes must be clearly documented.
- **Done means deployed.** Writing IaC is not the finish line — run the playbook, verify it works, then report completion. Never stop at "here's the code I wrote."
- Warnings are blockers. Resolve before considering work complete. If a warning truly cannot be resolved, document why.
- **Storage: prefer the foundation stores over raw PVCs.** New stateful workloads should back onto the foundation data stores on the R730xd — PostgreSQL, kv-cache (Valkey), versitygw (S3: s3-hot/s3-bulk) — reached over the LAN, rather than provisioning a raw in-cluster PVC. The foundation stores exist specifically to hold durable app state, and they are the *only* place it belongs — K8s node disks hold the OS and nothing else, never application state. Consolidating durable state on the R730xd keeps the management and recovery story in one place: back up, snapshot, and restore the foundation stores, not a scatter of per-node volumes. Reach for them first. Only provision a dedicated PVC when a workload genuinely can't use an external SQL/KV/S3 backend, and say why — and even then it should back onto foundation-provided storage (e.g. NFS from the R730xd), not a node's local disk. See [ADR-003](docs/decisions/003-foundation-stores-on-r730xd.md).
- Decision records: When a non-obvious choice is made, write an ADR in `docs/decisions/` (use `/adr` skill).
- **Active state only, everywhere but the history homes.** Comments, runbooks, templates, dashboards, playbooks, and every other working file must describe the system *as it is now* — never what it used to be, what it replaced, or how a since-completed migration ran. Historical context ("was X", "replaced Y", "coexists with Z until cutover") belongs **exclusively** in an ADR under `docs/decisions/` or the migration record under `archive/`. Don't leave "was MinIO"-style breadcrumbs in working files: they rot, mislead, and duplicate the ADR that already owns the story. When you finish a migration, strip its transitional language from the working files as part of finishing — the ADR keeps the memory. Pointers to archive files or superseded ADRs outside of those two directories *are still rot*, if a session needs to know what was, it can check archive or decisions.

# Operational Readiness Checklist

Every service, machine, or infrastructure component MUST have answers to the following before it is considered complete. If a question doesn't apply, document why.

## Observability
- **Health signal:** How do we know this is working right now? (e.g., systemd status, HTTP health endpoint, kubectl readiness probe, process check)
- **Metrics:** What should be measured? (e.g., disk usage, request latency, queue depth, CPU/memory) Where do metrics go?
- **Logs:** Where do logs live? Are they rotated? Can they be searched? (e.g., journald, file path, stdout to container runtime)

## Alerting
- **Failure detection:** How do we know when this breaks? What specifically triggers an alert? (e.g., service down, disk >90%, cert expiring, backup failed)
- **Alert destination:** Where do alerts go? (e.g., Ntfy, email, Slack, dashboard, UPS shutdown signal)
- **On-call response:** Who or what acts on the alert? Is there a runbook or is the fix obvious?

## Troubleshooting
- **First steps:** If this is down, what do you check first? (e.g., `systemctl status X`, `kubectl logs`, check upstream dependency)
- **Dependencies:** What does this depend on? What depends on this? (e.g., NFS requires R730xd network, K8s pods require NFS)
- **Common failure modes:** What's most likely to go wrong? (e.g., disk full, OOM, network unreachable, cert expired, DNS)
- **Recovery:** How do you restart or rebuild this? Is it automatic (systemd restart, K8s reschedule) or manual?

## Documentation
- **Decision record:** If a non-obvious choice was made, is there an ADR in `docs/decisions/`? (Use `/adr` skill)
- **Runbook:** For anything that requires multi-step recovery, is there a runbook?

When writing Ansible roles, scripts, or configs — if the operational story isn't addressed in the IaC itself (e.g., monitoring agent installed, health check configured, log rotation set up), flag it as a TODO or open question rather than silently skipping it.
