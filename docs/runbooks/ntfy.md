# Runbook — ntfy (platform push notifications)

Self-hosted [ntfy](https://ntfy.sh) as a shared platform service: any app publishes to a topic over HTTP and any subscriber (phone app, browser, another service) receives it. Manifests: `kubernetes/infrastructure/ntfy/`; Flux Kustomization: `kubernetes/clusters/grizzly-platform/ntfy.yaml`. Public URL: `https://ntfy.grizzly-endeavors.com` (Caddy wildcard → nginx ingress; TLS at the VPS). Decision: [ADR-061](../decisions/061-ntfy-notification-service.md).

This runbook is for **operating** ntfy. If you're building an app that sends or receives notifications, see the [integration guide](../integration/ntfy.md) (publish, subscribe, action buttons).

The server is **private** (`auth-default-access: deny-all`) — it's on the public internet, so nothing reads or writes a topic without an explicit grant. All access control lives in the auth DB on the PVC and is managed with the `ntfy` CLI inside the pod.

## Deploy

Committed to Flux; it reconciles automatically. Force it / check status:

```fish
flux reconcile kustomization ntfy --with-source
kubectl -n ntfy get pods,pvc,ingress
curl -s https://ntfy.grizzly-endeavors.com/v1/health   # {"healthy":true}
```

## Post-deploy — users, tokens, topic access

Run inside the pod (`exec`); state persists on the PVC. Example: an admin account, plus a scoped token for an app that only publishes to one topic.

```fish
set POD (kubectl -n ntfy get pod -l app.kubernetes.io/name=ntfy -o name)
# 1. an admin (full access) — you, for the web UI / phone app
kubectl -n ntfy exec -it $POD -- ntfy user add --role=admin bear
# 2. a least-privilege publisher for an app (deny-all default → grant one topic)
kubectl -n ntfy exec $POD -- ntfy user add appname
kubectl -n ntfy exec $POD -- ntfy access appname 'chores' rw
kubectl -n ntfy exec $POD -- ntfy token add appname   # prints tk_... — copy it
```

Store the app's token in 1Password for the consumer to read (never commit it):

```fish
op item edit platform-ntfy --vault grizzly-platform appname_token=tk_xxxxxxxx
```

Publish check (with the token):

```fish
curl -H "Authorization: Bearer tk_xxxxxxxx" -d "hello" https://ntfy.grizzly-endeavors.com/chores
```

## Alertmanager → phone for critical alerts

Discord carries every Alertmanager alert, but it is easy to miss, so `severity: critical` also pushes here. Alertmanager posts its own JSON schema, and ntfy renders it with the built-in **`alertmanager`** template (`?template=alertmanager`) so the push reads as a summary rather than raw JSON.

The identity and topic:

```fish
set POD (kubectl -n ntfy get pod -l app.kubernetes.io/name=ntfy -o name)
kubectl -n ntfy exec $POD -- ntfy user add alertmanager        # NTFY_PASSWORD=… for non-interactive
kubectl -n ntfy exec $POD -- ntfy access alertmanager 'platform-critical' rw
kubectl -n ntfy exec $POD -- ntfy token add alertmanager
op item edit observability-ntfy-critical --vault grizzly-platform token=tk_xxxxxxxx
```

Alertmanager reads that token via `vault_monitoring_ntfy_critical_token` and renders the receiver in `r730xd-prometheus`. Critical alerts route to a receiver holding **both** Discord and ntfy — not `continue: true`, because once a child route matches, the parent's receiver never fires. An empty token disables the route, leaving Discord-only as a valid configuration.

Verify routing without sending anything:

```fish
amtool config routes test --config.file=/opt/observability/prometheus/alertmanager.yml severity=critical alertname=ZFSPoolDegraded   # -> critical
amtool config routes test --config.file=/opt/observability/prometheus/alertmanager.yml severity=warning alertname=ContainerMemoryHigh   # -> default
```

## Operational readiness

- **Health:** `GET /v1/health`; the Deployment's readiness/liveness probes hit it. `kubectl -n ntfy get pods`.
- **Metrics:** ntfy can expose Prometheus metrics (`enable-metrics` in `config.yaml`) — off today; enable + add a ServiceMonitor if it becomes load-bearing.
- **Logs:** stdout → `kubectl -n ntfy logs deploy/ntfy`.
- **Alerting:** this *is* an alert channel; monitor it externally (Flux→Discord in `infrastructure/notifications/` is the independent path so a ntfy outage is still noticed).
- **Dependencies:** iscsi-zfs-retain StorageClass (democratic-csi on the R730xd) for the PVC; ingress-nginx + the VPS Caddy for exposure. No database/SSO dependency.
- **Common failures:** pod stuck `ContainerCreating` → PVC/iSCSI attach (check `kubectl -n ntfy describe pvc ntfy-data`); 403 on publish → missing/expired token or topic grant (`ntfy access`); subscriptions dropping at ~60s → ingress `proxy-read-timeout` (set to 3600 here).
- **Recovery:** stateless pod — `kubectl -n ntfy rollout restart deploy/ntfy` reschedules and re-attaches the PVC. The auth DB survives on the retained volume.
- **Backup:** the auth/cache DBs live on the retained iscsi-zfs volume (survives PVC delete). A periodic `sqlite3 .backup` CronJob to nfs-mergerfs is a reasonable follow-up if the token set grows.
