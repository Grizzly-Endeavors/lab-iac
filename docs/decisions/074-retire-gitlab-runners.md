# ADR-074: Retire the Self-Hosted GitLab Runner Pool

**Date:** 2026-08-23
**Status:** accepted
**Supersedes:** [ADR-071](071-self-hosted-gitlab-runners.md) (self-hosted GitLab runners in an isolated namespace pair)

## Context

ADR-071 stood up a GitLab Runner pool on the cluster so a GitLab SaaS group's pipelines would not burn the trial's 400 compute minutes. That group is no longer using the cluster for CI. The runner object was removed on the GitLab side, which invalidated the `glrt-…` authentication token the manager registers with: every start exhausted its 30 registration attempts with `Verifying runner... is not valid`, the liveness probe killed the pod, and it crash-looped — 900+ restarts over ten days, with no pipeline ever waiting on it.

A runner that nothing dispatches to is pure cost: a crash-looping pod, a Prometheus scrape job, two alert rules, a NodePort, a network-policy set, RBAC, and a runbook, all guarding a workload with no consumer.

## Decision

**Remove the pool entirely.** The `gitlab-runners` Flux Kustomization and everything under `kubernetes/infrastructure/gitlab-runners/` are deleted; Flux prunes both namespaces. The Prometheus `gitlab-runner` scrape job, its target file, the `GitLabRunnerDown` / `GitLabRunnerJobsQuotaExhausted` alerts, NodePort 30895, and the operator runbook go with it.

The 1Password item `cicd-gitlab-runner` holds only the revoked token and can be deleted at the operator's convenience; nothing reads it.

ADR-071's design — the two-namespace split, internet-only egress, IPv6 denial, no distributed cache — stays on record as the pattern to reuse if a foreign-trust CI pool is ever needed again. Nothing about it was found wanting; it was retired for lack of demand, not for a defect.

## Alternatives Considered

- **Re-register with a fresh token.** Stops the crash loop but restores a runner no pipeline uses. The honest fix for "unused" is removal, not repair.
- **Scale the Deployment to zero and keep the manifests.** Leaves the manifests, alerts, NodePort and runbook describing a thing that does not exist, and the `GitLabRunnerDown` alert permanently firing or permanently silenced. Dormant IaC rots; the ADR keeps the design if it is wanted back.

## Consequences

- No GitLab CI runs on the cluster. GitLab-hosted runners (or a re-deployment from the ADR-071 pattern) are the path if that changes.
- The ARC pool in `arc-runners` remains the only self-hosted CI on the platform.
