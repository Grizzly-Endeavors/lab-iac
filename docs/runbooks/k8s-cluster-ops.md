# K8s Cluster — Standup, Rejoin & Upgrade

Operator entry point for building, rebuilding, or upgrading the K8s cluster ([ADR-014](../decisions/014-k8s-cluster-stack.md) stack, [ADR-016](../decisions/016-single-control-plane.md) single control plane). Each playbook below is self-documenting — its header has the full usage, prerequisites, and verification steps; this page is the map of *which playbook, in what order*, not a copy of their content.

## Full cluster standup (from bare metal)

Run in order. `dell-inspiron-15` is the control plane; `quanta`/`intel-nuc`/`optiplex` are workers.

1. Image nodes: `scripts/build-worker-iso.sh` (workers) — the control plane node uses `scripts/build-laptop-iso.sh`.
2. `ansible-playbook -l k8s_cluster ansible/playbooks/setup-k8s-worker.yml` — baseline OS config on every node (yes, including the control plane; the name predates that).
3. `ansible-playbook -l k8s_cluster ansible/playbooks/setup-k8s-containerd.yml` — container runtime on every node.
4. `ansible-playbook ansible/playbooks/setup-k8s-control-plane.yml` — kubeadm init + Cilium on `dell-inspiron-15`.
5. `ansible-playbook ansible/playbooks/join-k8s-workers.yml` — join all workers (or `-l <node>` for one).
6. `ansible-playbook ansible/playbooks/setup-k8s-cluster-metrics.yml` — wire cluster metrics into R730xd Prometheus.
7. `ansible-playbook ansible/playbooks/setup-k8s-storage.yml` — democratic-csi storage provisioning.
8. `ansible-playbook ansible/playbooks/setup-k8s-gitops.yml` — Flux bootstrap.
9. `ansible-playbook ansible/playbooks/setup-k8s-cicd.yml` — ARC runners + Argo Workflows.
10. `ansible-playbook ansible/playbooks/setup-k8s-ingress.yml` — ingress-nginx + cert-manager + external access.
11. `ansible-playbook ansible/playbooks/setup-k8s-registry-trust.yml` — containerd trust for the in-cluster registry.
12. `ansible-playbook ansible/playbooks/setup-1password-eso.yml` — writes the ESO service account token + `onepassword` ClusterSecretStore wiring.

Each playbook's own header states its specific prerequisites and verification commands — read those before running. The original run of this sequence (with narrative, screenshots-in-prose, and troubleshooting notes from the actual 2026 standup) is archived at [`archive/migration-2026/k8s-cluster-standup.md`](../../archive/migration-2026/k8s-cluster-standup.md) — useful for historical context, not for operating the cluster today.

## Rebuilding or rejoining a single worker

1. Image the node: `scripts/build-worker-iso.sh`.
2. `ansible-playbook -l <node> ansible/playbooks/setup-k8s-worker.yml`
3. `ansible-playbook -l <node> ansible/playbooks/setup-k8s-containerd.yml`
4. `ansible-playbook ansible/playbooks/join-k8s-workers.yml -l <node>`

There is no dedicated node-removal playbook. Draining and removing a node is the standard manual `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` + `kubectl delete node <node>` + `kubeadm reset` on the node itself.

## A node is down and its workloads are stuck

When a node stops answering, Kubernetes evicts its pods but cannot finish: a delete completes only once a kubelet confirms the kill, so every pod on that node hangs in `Terminating` — still reporting `Running`, still holding its old pod IP — for as long as the node stays down. Anything with a finalizer waiting on those pods (an Agones `GameServer`, a PVC behind `pvc-protection`) is pinned with them, and an RWO volume stays attached to the dead node until its pod object is actually gone.

Confirm that's the shape before acting:

```bash
kubectl get nodes                                   # the node reads NotReady
kubectl get pods -A --field-selector spec.nodeName=<node>
kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.deletionTimestamp) | "\(.metadata.namespace)/\(.metadata.name) \(.metadata.deletionTimestamp)"'
```

**If the node can come back, bring it back** — that resolves everything on its own. The kubelet reaps the stranded pods within seconds of booting.

**If it can't come back soon**, apply the non-graceful-shutdown taint. This is the sanctioned path: it force-deletes the node's pods *and* detaches their volumes, so RWO workloads can reschedule elsewhere.

```bash
kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# ...once the node is genuinely back and Ready:
kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
```

Only apply it to a node you have confirmed is actually down. On a node that is merely partitioned, its workloads may still be running and writing, and force-detaching a volume out from under a live writer is how filesystems get corrupted.

`grizzly-gameservers` recovers its own game servers without this taint — it force-deletes the stranded pod inside its namespace instead, deliberately, so the bot never needs cluster-scoped node permissions ([its ADR-009](https://github.com/Grizzly-Endeavors/grizzly-gameservers/blob/main/docs/decisions/009-stranded-instance-recovery.md)). Other namespaces have no such reconciler, so the taint is the tool for everything else.

## Upgrading the cluster version

Three playbooks cover the version stack, each self-documenting in its header. None of them skip minor versions — K8s (kubeadm), Cilium, and containerd all move one step per run, so a multi-minor catch-up is several runs in sequence ([ADR-068](../decisions/068-k8s-135-stepped-upgrade.md) records a full example, including the component-compatibility checks to make before picking a target).

- **K8s:** `ansible-playbook ansible/playbooks/upgrade-k8s-cluster.yml` — control plane first, then workers one at a time (`serial: 1`). Update `kubernetes_version` in `ansible/inventory/group_vars/k8s_cluster/k8s.yml` first. Single control plane means brief API downtime during the control-plane play.
- **Cilium:** `ansible-playbook ansible/playbooks/upgrade-cilium.yml` — runs the upstream-required pre-flight chart, then the Helm upgrade. Update `cilium_version` in `ansible/roles/k8s-cilium/defaults/main.yml` first and check the target's K8s compatibility matrix.
- **containerd:** `ansible-playbook ansible/playbooks/upgrade-containerd.yml` — drains each node and swaps the pinned package ([ADR-067](../decisions/067-containerd-from-docker-repo.md)). Update `containerd_version` in `ansible/roles/k8s-containerd/defaults/main.yml` first and check the [K8s support matrix](https://github.com/containerd/containerd/blob/main/RELEASES.md).

Before any node-draining run: take an etcd snapshot (`etcdctl snapshot save` inside the etcd pod, copy off-node), and shut down any running game servers through the gameservers bot — their `safe-to-evict: false` PDB blocks drains by design.
