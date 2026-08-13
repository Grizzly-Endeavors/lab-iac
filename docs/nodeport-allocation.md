# NodePort Allocation

All K8s services exposed via NodePort, used by R730xd Prometheus for
external scraping and by the VPS ingress path (ADR-019).

Kubernetes default NodePort range: 30000-32767.

| Port  | Service                        | Purpose                          | Source File                                            |
|-------|---------------------------------|-----------------------------------|--------------------------------------------------------|
| 30356 | ingress-nginx HTTPS            | External HTTPS traffic via VPS   | `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` |
| 30487 | ingress-nginx HTTP              | External HTTP traffic via VPS    | `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` |
| 30500 | OCI registry                    | containerd pulls via localhost   | `kubernetes/infrastructure/registry/service.yaml`      |
| 30881 | flux source-controller metrics  | Prometheus scraping              | **not in repo** — applied manually, see note below     |
| 30882 | flux kustomize-controller metrics | Prometheus scraping            | **not in repo** — applied manually, see note below     |
| 30883 | flux helm-controller metrics    | Prometheus scraping              | **not in repo** — applied manually, see note below     |
| 30884 | flux notification-controller metrics | Prometheus scraping         | **not in repo** — applied manually, see note below     |
| 30885 | ARC controller metrics          | Prometheus scraping              | `kubernetes/infrastructure/github-runners/metrics-service.yaml` |
| 30886 | Argo controller metrics         | Prometheus scraping              | `kubernetes/infrastructure/argo-workflows/metrics-services.yaml` |
| 30887 | Argo server metrics             | Prometheus scraping              | `kubernetes/infrastructure/argo-workflows/metrics-services.yaml` |
| 30888 | cert-manager metrics            | Prometheus scraping              | `kubernetes/infrastructure/cert-manager/metrics-service.yaml` |
| 30889 | ingress-nginx metrics           | Prometheus scraping              | `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` |
| 30890 | kyverno admission metrics       | Prometheus scraping              | `kubernetes/infrastructure/kyverno/metrics-service.yaml` |
| 30891 | authentik-server metrics        | Prometheus scraping              | `kubernetes/infrastructure/authentik/metrics-service.yaml` |
| 30892 | grizzly-invite metrics          | Prometheus scraping              | `kubernetes/apps/grizzly-invite` (Helm chart values)   |
| 30893 | career-scanner metrics          | Prometheus scraping              | career-scanner chart values (Flux HelmRelease)         |
| 30894 | GitLab Runner manager metrics   | Prometheus scraping              | `kubernetes/infrastructure/gitlab-runners/metrics-service.yaml` |
| 30080 | kube-state-metrics              | Prometheus scraping              | **not in repo** — applied manually, see note below     |
| 30025 | Stalwart SMTP (25)              | Inbound mail via HAProxy/tunnel  | `kubernetes/infrastructure/stalwart/service.yaml`      |
| 30465 | Stalwart submissions (465)      | Implicit-TLS submission via VPS  | `kubernetes/infrastructure/stalwart/service.yaml`      |
| 30587 | Stalwart submission (587)       | STARTTLS submission via VPS      | `kubernetes/infrastructure/stalwart/service.yaml`      |
| 30993 | Stalwart IMAPS (993)            | IMAP over TLS via VPS            | `kubernetes/infrastructure/stalwart/service.yaml`      |

Outside the NodePort range entirely: `game-servers/minecraft` uses port **7000**, allocated by Agones from its own configured port range rather than this table's conventions — expected, not an error.

## Conventions

- **30356-30500**: Traffic-carrying services (ingress, registry)
- **300xx (mail)**: Stalwart mail ports use a mnemonic mapping — the last three digits equal the mail port (25→30025, 465→30465, 587→30587, 993→30993) — so the VPS HAProxy port map (ADR-051, load-bearing) is unambiguous.
- **30881-30894**: Metrics endpoints for Prometheus
- New allocations should pick the next available port in the appropriate range

**Manual, non-IaC services (30881-30884, 30080):** these NodePorts exist live in the cluster (confirmed via `kubectl`) but have no corresponding manifest anywhere in this repo — `kubectl.kubernetes.io/last-applied-configuration` on the flux-system ones shows they were `kubectl apply`'d directly, and `kube-state-metrics` is a bare `helm install` outside Flux. This violates the repo's IaC-only rule (root `CLAUDE.md`). Documented here so Prometheus scrape targets are explained, but they should be converted to tracked manifests (a Flux-managed `HelmRelease`/kustomization for `kube-state-metrics`, plain `Service` YAML for the four flux-system metrics ports) rather than left as drift.
