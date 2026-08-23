# 035: Internal TLS foundation via OpenBao PKI

**Date:** 2026-06-29
**Status:** superseded by [ADR-073](073-retire-openbao.md) — never implemented; the cluster has only the Let's Encrypt and self-signed issuers, and the OpenBao PKI this depended on is retired
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md), [ADR-024](024-platform-secrets-on-openbao.md), [ADR-027](027-registry-zot.md), [ADR-032](032-registry-pullthrough-cache.md), [ADR-034](034-in-cluster-wireguard-encryption.md), [ADR-036](036-internal-dns-zone.md)
**Tracking:** [#56](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/56)

## Context

The in-cluster zot registry serves plain HTTP, so every consumer carries an "insecure" escape hatch — kaniko `--insecure` (both build workflows), Argo `insecure: true`, Kyverno `allowInsecure: true`, and node containerd pulling over an `http://localhost:30500` mirror. cert-manager is installed but only with a self-signed ClusterIssuer (ADR-019 deferred a real CA until a workload needed one). As the platform onboards more apps — many of which expect TLS by default — the recurring `--insecure` friction and the absence of an internal CA is a foundation gap, not a one-off. OpenBao is already the platform secrets source of truth with a working Kubernetes auth method (ADR-024).

The goal is not to silence one registry warning but to build the reusable internal-TLS foundation once, so every future service gets a trusted HTTPS endpoint without per-app trust plumbing.

## Decision

**Stand up the OpenBao PKI secrets engine as the internal CA, with cert-manager issuing leaf certificates from it and trust-manager distributing the CA bundle cluster-wide.** zot is the first consumer: it serves native TLS and its `--insecure`-style flags are removed.

1. **Trust root: OpenBao PKI engine** (root + intermediate), reusing the existing Kubernetes auth method (new role → PKI policy). One central, auditable, rotatable CA coherent with secrets-on-OpenBao — not a separate one-off trust root.
2. **Issuance: cert-manager `Vault` ClusterIssuer** pointed at OpenBao PKI (OpenBao is Vault-API-compatible). This is the first CA-backed issuer; the self-signed issuer stays for internal/webhook use.
3. **Trust distribution, split by client population:** trust-manager publishes the CA bundle as a ConfigMap into every namespace for in-cluster clients (kaniko, dind, Kyverno); the existing `k8s-registry-trust` Ansible role drops the same CA into node `certs.d` for containerd.
4. **zot serves native TLS** with a cert-manager leaf cert whose SANs cover **both** `registry.registry.svc.cluster.local` (in-cluster ClusterDNS clients) **and** `localhost` (the node-pull loopback NodePort mirror). The `--insecure` / `allowInsecure` / `insecure` flags on kaniko, Argo, and Kyverno are then removed.

## Alternatives Considered

- **cert-manager-managed self-signed CA.** Lighter to stand up and a real internal PKI, but a trust root *separate* from OpenBao — another authority to manage. Rejected for coherence; OpenBao PKI keeps one trust authority and can issue beyond the cluster later.
- **Public Let's Encrypt wildcard inside the cluster.** Zero CA distribution (system trust store), but forces public hostnames + split-horizon DNS and cannot issue for private names — incompatible with the `.internal` zone in ADR-036. Rejected.
- **Service mesh mTLS.** Heavy, and identity/authz is not the immediate goal; CiliumNetworkPolicy already covers segmentation. Rejected.
- **Keep the `--insecure` flags (rely on ADR-034 for confidentiality).** Cilium encryption does make the registry traffic genuinely encrypted on the wire, so the flags are not a confidentiality hole — but they remain a recurring authenticity gap and a stumbling block for apps that refuse non-TLS endpoints. Rejected as the foundation we want to stand on.

## Consequences

- **A real internal PKI** — every future app gets a trusted HTTPS endpoint cheaply, and the `--insecure` flags drop from existing consumers. This is the stable foundation the decision is for.
- **The loopback dual-SAN nuance is load-bearing.** Node containerd reaches zot at `localhost:30500` (it cannot resolve ClusterDNS — ADR-032), so the cert *must* include `localhost` or node pulls break. This is the non-obvious bit a naive "just turn on TLS" would trip over.
- **New components:** the OpenBao PKI engine and trust-manager. trust-manager handles in-cluster trust; node trust still rides the `k8s-registry-trust` role — two distribution paths, by design.
- **Certificate lifecycle becomes an operational concern.** cert-manager auto-renews leaf certs; OpenBao CA rotation is a deliberate operational item (runbook territory).
- **Open verification item:** confirm the cert-manager `Vault` issuer authenticates cleanly against OpenBao PKI via the existing Kubernetes auth method (AppRole/K8s) for the issue path before committing the manifests.
- **Reinforced by ADR-036:** a private `.internal` DNS zone can *only* be served by a private CA (LE will not issue for non-public names), so the DNS choice and this PKI choice require each other rather than competing.
- **Pairs with ADR-034:** transport encryption (Cilium) plus authenticity (this PKI) is defense in depth, each at the right layer.
