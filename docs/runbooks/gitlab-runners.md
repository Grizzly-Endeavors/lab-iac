# GitLab Runners — operator runbook

Self-hosted GitLab CI runners for a GitLab SaaS group, using the Kubernetes
executor. Jobs run in an isolated namespace with internet-only egress.
Architecture and the reasoning behind the isolation:
[ADR-071](../decisions/071-self-hosted-gitlab-runners.md).

## Components at a glance

| Piece | Where |
|---|---|
| Manager Deployment | `gitlab-runners` namespace, `gitlab-runner` HelmRelease (chart `0.91.0`, runner `19.2.0`) |
| Job pods | `gitlab-runner-jobs` namespace, created and torn down per CI job |
| Manifests | `kubernetes/infrastructure/gitlab-runners/`, applied by its own Flux Kustomization `kubernetes/clusters/grizzly-platform/gitlab-runners.yaml` |
| Runner auth token | 1Password `cicd-gitlab-runner/token` → ESO → `gitlab-runner-token` secret |
| Network confinement | `network-policy.yaml` — DNS + IPv4 internet, no LAN, no IPv6 |
| RBAC | `rbac.yaml` — executor minimum in the job namespace; job pods get nothing |
| Metrics | NodePort 30895 → Prometheus job `gitlab-runner` |

Job pods are `gitlab-runner-jobs`-only and hold no platform credentials. They
cannot reach anything on the LAN — the foundation stores, the secret store, zot,
the BMCs, or the router.

## Bootstrap (one-time)

1. **Create the runner in GitLab.** In the group, go to **Build → Runners →
   New group runner**. Set:
   - **Tags** — leave empty and tick **"Run untagged jobs"**, so every project
     in the group picks the runner up without editing its `.gitlab-ci.yml`.
   - **Maximum job timeout** — leave blank; the runner enforces 3600s itself.

   GitLab shows a `glrt-…` authentication token exactly once. Copy it.

   Tags, `locked`, `protected`, and run-untagged are properties of the runner
   *object in GitLab*, not of the chart. The chart strips those flags when the
   token starts with `glrt-`, so setting them in `helmrelease.yaml` does
   nothing — change them in the GitLab UI.

2. **Store the token in 1Password** (vault `grizzly-platform`, item
   `cicd-gitlab-runner`, field `token`). Paste at the prompt so the value never
   lands in shell history:

   ```sh
   eval $(op signin)
   op item create --category=password --vault=grizzly-platform \
     --title=cicd-gitlab-runner 'token[password]='
   ```

3. **Let Flux reconcile**, then confirm the chain end to end:

   ```sh
   flux reconcile kustomization gitlab-runners --with-source
   kubectl -n gitlab-runners get externalsecret gitlab-runner-token   # SecretSynced
   kubectl -n gitlab-runners rollout status deploy/gitlab-runner
   kubectl -n gitlab-runners logs deploy/gitlab-runner | grep -i "registered\|verify"
   ```

   The runner should show **online** in the GitLab group's Runners page.

   The HelmRelease will retry-fail until the 1Password item exists — that is
   the expected state between steps 1 and 2, not a fault. It is contained to
   this pool's own Flux Kustomization and does not hold back the rest of the
   platform; see ADR-071 for why that separation is load-bearing.

## Using the runner from a project

With "Run untagged jobs" enabled, nothing project-side is required:

```yaml
test:
  image: node:24-alpine
  script:
    - npm ci
    - npm test
```

There is **no distributed cache** (ADR-071), so `cache:` entries do not survive
between jobs — every job installs cold. `artifacts:` works normally; those go
to GitLab over the internet.

### Building images

Builds use rootless BuildKit rather than a privileged `docker:dind` service,
so `docker build` recipes copied from the internet will not work. The
equivalent:

```yaml
build-image:
  image:
    name: moby/buildkit:v0.31.1-rootless
    entrypoint: [""]
  variables:
    BUILDKITD_FLAGS: --oci-worker-no-process-sandbox
  script:
    - |
      buildctl-daemonless.sh build \
        --frontend dockerfile.v0 \
        --local context=. \
        --local dockerfile=. \
        --output "type=image,name=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA,push=true"
  before_script:
    - mkdir -p ~/.docker
    - |
      echo "{\"auths\":{\"$CI_REGISTRY\":{\"auth\":\"$(printf '%s:%s' "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" | base64 -w0)\"}}}" > ~/.docker/config.json
```

Pin the BuildKit tag rather than tracking `latest`, and check the current
release before bumping it.

## Operations

### Health

```sh
kubectl -n gitlab-runners get deploy gitlab-runner
kubectl -n gitlab-runner-jobs get pods          # job pods, only while jobs run
kubectl -n gitlab-runner-jobs describe quota jobs-quota
```

The authoritative signal is the GitLab group's Runners page: the manager
heartbeats every few seconds and shows **online** there.

### Metrics and alerts

Prometheus scrapes NodePort 30895 as job `gitlab-runner`. Two alerts fire to
the usual destination:

| Alert | Meaning | Response |
|---|---|---|
| `GitLabRunnerDown` | Manager unreachable 5m — CI jobs queue unpicked | Check the Deployment and its logs; usually a failed token sync |
| `GitLabRunnerJobsQuotaExhausted` | Job namespace above 90% of its CPU quota for 15m | Look for leaked job pods; raise the quota in `resource-limits.yaml` if the load is real |

### Logs

Manager logs are JSON on stdout: `kubectl -n gitlab-runners logs deploy/gitlab-runner`.
Per-job logs live in the GitLab job page; the pod is deleted when the job ends,
so grab `kubectl -n gitlab-runner-jobs logs <pod>` while it is still running.

## Failure modes

**Runner shows offline / jobs stay queued.** Check the token chain first — it
is the usual cause.

```sh
kubectl -n gitlab-runners get externalsecret gitlab-runner-token
kubectl -n gitlab-runners logs deploy/gitlab-runner | tail -50
```

A revoked or rotated token surfaces as a registration failure loop in the logs.
Re-create the runner in GitLab, update the 1Password field, then
`kubectl -n gitlab-runners rollout restart deploy/gitlab-runner`.

**Job pods stuck `Pending`.** Almost always the quota:

```sh
kubectl -n gitlab-runner-jobs describe quota jobs-quota
kubectl -n gitlab-runner-jobs get events --sort-by=.lastTimestamp | tail
```

Leaked pods from a killed job can be deleted directly; the executor will not
re-adopt them.

**A job hangs on a network connection, then times out.** Expected for anything
reaching the LAN or IPv6 — both are denied by design. Confirm what it was
trying to reach:

```sh
kubectl -n gitlab-runner-jobs exec <pod> -- getent hosts <target>
```

If the target is a LAN address, the pipeline is asking for something this pool
deliberately cannot do. If it is a public host that only has an AAAA record,
the pool cannot reach it at all — see ADR-071 for why IPv6 is refused rather
than filtered.

**`docker: command not found` / `Cannot connect to the Docker daemon`.** There
is no DinD sidecar. Port the job to the BuildKit recipe above.

**Rootless BuildKit fails with a user-namespace or `newuidmap` error.** Check
that nothing has set `allow_privilege_escalation = false` in
`helmrelease.yaml` — that applies `no_new_privs` and breaks the setuid helpers
BuildKit needs.

## Recovery

The whole pool is Flux-managed and stateless apart from the token. To rebuild:

```sh
flux reconcile kustomization gitlab-runners --with-source
```

If the release is wedged, delete it and let Flux reinstall — no state is lost,
and in-flight jobs fail and can be retried from the GitLab UI:

```sh
kubectl -n flux-system delete helmrelease gitlab-runner
flux reconcile kustomization gitlab-runners
```

Uninstalling deregisters the runner from GitLab (`unregisterRunners: true`), so
a rebuilt pool needs a fresh runner created per the bootstrap steps above.
