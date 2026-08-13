# ADR-071: Self-Hosted GitLab Runners in an Isolated Namespace Pair

**Date:** 2026-08-13
**Status:** Accepted
**Relates to:** [ADR-057](057-container-builds-buildkit.md) (rootless BuildKit for image builds), [ADR-063](063-gate-runs-in-cluster.md) (the GitHub-side runner/gate split), [ADR-016](016-single-control-plane.md) (single control plane), [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores)

## Context

A GitLab SaaS trial comes with 400 CI compute minutes, which is not enough to exercise pipelines across several projects. Self-hosted runners do not consume that allowance at all, and the cluster already has spare capacity — it idles well under its 64 CPU / 168 Gi ceiling.

The platform already runs a self-hosted CI pool: ARC in `arc-runners`, serving the `grizzly-endeavors` GitHub org. Reusing it would have been the smallest change, but the two pools have different trust profiles and that difference is the whole design problem.

`arc-runners` is deliberately permissive. Runner pods carry S3 credentials for the sccache bucket, hold RBAC to create Jobs in their own namespace, run a privileged DinD sidecar, and have unrestricted reach to the LAN — the foundation stores, OpenBao, the BMCs, the router. That is acceptable because everything executing there is first-party code from repos on this platform.

The GitLab pool serves a work group. The code is internal company applications, and anyone who can push a branch in that group gets code execution on this hardware. The pool therefore has to assume its workloads are not trusted with the platform's credentials or its network.

A second constraint shaped the network design. The cluster is dual-stack (`enable-ipv6-masquerade = true`), and the LAN's IPv6 prefix is a dynamic delegation from the ISP. A pod's ULA address is masqueraded to its node's global address on the way out, so an IPv6-capable job can reach LAN hosts on their global addresses.

## Decision

A GitLab Runner deployment using the Kubernetes executor, in **two namespaces** rather than one:

- **`gitlab-runners`** holds the manager. It carries the runner authentication token and needs Kubernetes API access to create job pods.
- **`gitlab-runner-jobs`** is where CI job pods land. It holds no credentials and has no API access.

The split is the boundary. Code from the GitLab group runs only in `gitlab-runner-jobs`, where it cannot read the token that would let it impersonate the runner to GitLab, and cannot reach the API server. Job pods run as a ServiceAccount with no rules and `automountServiceAccountToken: false`, so they get no Kubernetes surface at all — not even self-inspection. RBAC is written by hand because the chart's `rbac.create` grants core-API `*`/`*` when `rbac.rules` is empty; ours is the documented executor minimum, scoped to the job namespace.

**Egress is IPv4 internet only, and IPv6 is denied outright.** Job pods may reach DNS and the public IPv4 internet with RFC1918, link-local, and loopback excluded — no LAN, no foundation stores, no OpenBao, no other namespace. The manager gets the same rule plus a single hole to the API server on `10.0.0.226:6443`. IPv6 is refused rather than filtered because there is no stable value to write in an except list: an "allow `::/0` except the LAN prefix" rule would silently reopen the entire LAN the moment the ISP rotates its delegation, and a boundary that fails open without a signal is worse than no boundary. Job pods get the glibc `no-aaaa` resolver option so tooling skips the AAAA lookup rather than stalling on a dropped IPv6 connect.

**Image builds use rootless BuildKit, not privileged DinD** — the same mechanism ADR-057 chose for in-cluster builds. `privileged = false` holds for every job container.

**No distributed cache.** GitLab CI caches need object storage the runner can reach, and the only candidate is versitygw on the LAN. Wiring it would mean punching a hole through the egress policy *and* handing bucket credentials to the helper container, where job code could read them. Artifacts still work — they go to GitLab over the internet — so the cost is falling back to per-job cold caches.

The pool gets **its own Flux Kustomization** rather than joining the `infrastructure` one. That is not only blast-radius hygiene: the manager pod does not start until ESO has synced its runner token, and inside `infrastructure` that unready pod would hold `infrastructure` short of Ready — which gates the `external-secrets-stores` Kustomization that the `onepassword` ClusterSecretStore comes from, and eleven other Kustomizations besides. Placed there, a missing token would stall GitOps for the whole platform and could not resolve itself. The ExternalSecret therefore lives next to the workload, matching langfuse and metabase.

**A `ResourceQuota` caps the job namespace** at 32 CPU / 64 Gi of limits and 24 pods. A pipeline that leaks pods exhausts its own quota and stalls its own CI without starving the platform's real workloads.

## Alternatives Considered

- **Reuse the `arc-runners` pool.** Cheapest, and jobs would inherit the zot pull-through cache. It also hands work CI the sccache credentials, the gate Job RBAC, and full LAN reach. Rejected — that is exactly the exposure the pool needs not to have.
- **A dedicated VM on the R730xd with the docker executor.** A genuinely separate blast radius. Costs a machine to provision, patch, and monitor, plus a second CI pattern that matches nothing else in this repo. Rejected as disproportionate for a trial; it remains the escalation path if the workloads stop being internal apps.
- **Privileged DinD for builds.** Every `docker build` recipe on the internet works unmodified, which matters when experimenting. It also puts privileged containers running work code on cluster nodes — the weakest boundary available, and the one hardest to walk back once pipelines depend on it. Rejected.
- **Two runner deployments split by job tag**, one hardened and one relaxed for BuildKit, so only opted-in jobs get unconfined seccomp. The right shape if the trust assumption weakens, but it doubles the deployments, tokens, and 1Password entries, and puts a "which tag do I need" decision on every pipeline. Deferred — it is a copy of the HelmRelease when wanted.
- **A single runner using `configOverride`** with two `[[runners]]` blocks, achieving the tag split in one deployment. The chart writes `configOverride` verbatim into a ConfigMap and skips `register`, which would put the `glrt-` tokens in plaintext in a ConfigMap. Rejected.

## Consequences

- GitLab CI stops consuming the trial's 400 compute minutes; concurrency is 4 jobs, bounded by the namespace quota rather than by a billing meter.
- Pipelines get no cross-job cache, so dependency installs and compiles run cold every time. Slower than GitLab-hosted runners for cache-heavy pipelines. Adding a dedicated versitygw bucket is the fix, at the cost of an egress hole and credentials reachable from job code.
- `allow_privilege_escalation` is left unset rather than forced to `false`. Setting it applies `no_new_privs`, which breaks the setuid `newuidmap`/`newgidmap` that rootless BuildKit needs to open its user namespace. `privileged = false` carries the weight instead.
- Unconfined seccomp and AppArmor apply to **every** build container, not only the ones running BuildKit, because the executor sets the security context per-runner and not per-job. This widens the container-escape surface for all job code; the tag split above is the escalation path.
- Job pods are IPv4-only. A pipeline that genuinely needs IPv6 egress will fail, and the fix is a documented exception rather than a config toggle.
- The manager's API-server rule pins `10.0.0.226`. If the control plane is ever rebuilt on another address the runner fails to register loudly, rather than quietly losing its boundary.
- The residual exposure is the node kernel: job pods are unprivileged and network-confined, but they share a kernel with platform workloads on whichever node schedules them. Nothing here defends against a kernel escape — that is what the dedicated-VM alternative would buy.
