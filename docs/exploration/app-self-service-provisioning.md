# App Self-Service Provisioning — a platform control plane for foundation resources

**Date:** 2026-07-07
**Status:** Exploring — design shape agreed (aggregate `App` CR, additive-only controllers, per-foundation split). Not built. No go/no-go yet. Recorded as a light decision in [ADR-059](../decisions/059-app-self-service-provisioning.md); this doc is the depth behind it.

## The problem, precisely

Under [ADR-020](../decisions/020-app-delivery-model.md), an app already owns most of its infrastructure in its own repo: the `deploy/` Helm chart holds the ingress, ExternalSecret, service, deployment, even the Authentik outpost. Routine deploys and image bumps are a `git push` in the app repo — no grizzly-platform PR. That half is solved.

What is *not* self-service is **consuming a foundation store or the IdP**. Those are provisioning operations against shared, privileged systems, and today the operator is the reconciler:

- **Postgres:** hand-seed the 1Password item `stores-<app>`, then run `ansible-playbook setup-<app>-stores.yml` against the R730xd, which `docker exec`s into `foundation-postgres` and runs `CREATE ROLE` / `CREATE DATABASE ... OWNER`. Not in GitOps at all — it's a terminal session.
- **S3 (versitygw):** same shape — a `userplus` account + bucket created via the gateway admin API with root creds, keys seeded into 1Password by hand.
- **Valkey:** an ACL user, similar.
- **SSO (Authentik):** a blueprint file committed to `kubernetes/infrastructure/authentik/blueprints/<app>.yaml` (a grizzly-platform PR against a shared kustomization) *and* the `client_id`/`client_secret` injected into the shared Authentik **worker's** `global.env`, so every new OIDC client also redeploys the worker.

Two consequences: (1) any app needing a foundation change funnels through the operator, who is the serialization point when several apps move at once; (2) getting a database is not a git operation — it's being at a keyboard on the control node.

## Why solve this now (the shape of the bet)

This is deliberately over-built for the current eight apps. The cluster idles at ~1/10th capacity, app count is expected to grow, and the operating principle is to **frontload effort into a build-once system and never do the manual work again**. So the target is not "make the manual step nicer" — it's "delete the manual step." Onboarding an app should touch grizzly-platform zero times after a one-time pointer and never require the operator at a terminal. That reframes the whole thing from a workflow tweak into building a small **internal control plane** on top of the foundations.

## End state

A new app is: a repo with a `deploy/` chart, one `App` custom resource, and a one-time Flux pointer registered in grizzly-platform. `git push`. The cluster provisions the database, the bucket, the cache user, and the OIDC client, lands their credentials in 1Password, and the app's existing ExternalSecrets pull them. The operator is never in the loop to *add* — only to *see* and to *remove*.

```
app repo (git push)
  ├── deploy/                     # workload chart (unchanged from ADR-020)
  └── platform/app.yaml           # the App CR — the whole self-service surface
        │
        ▼
   App CR (platform.grizzly.io/v1, in the app's namespace)
        │  watched by
        ▼
   ┌─────────────────── provisioning controllers (per foundation) ───────────────────┐
   │  postgres-ctl   s3-ctl→broker   valkey-ctl   sso-ctl                             │
   │      │               │             │            │                                │
   │      ▼               ▼             ▼            ▼                                 │
   │  CREATE ROLE     create acct   ACL SETUSER  add OAuth2                            │
   │  +DB, revoke     +bucket       (scoped)     provider+app                          │
   │  self-admin      (root in                   (RBAC add_* only)                     │
   │      │            broker)         │            │                                 │
   │      └───────────────┴────────────┴────────────┘                                 │
   │                      │ mints generated creds (create/update only)                │
   │                      ▼                                                            │
   │                    1Password  item  stores-<app>                                  │
   └──────────────────────┬───────────────────────────────────────────────────────────┘
                          │ read (separate, read-scoped identity)
                          ▼
                 app's ExternalSecret ──▶ K8s Secret ──▶ pod
```

grizzly-platform stops being a place you edit per app and becomes the home of the machine: the CRDs and controllers. App repos consume the machine; they never touch it.

## The aggregate `App` custom resource

One CR, one block per foundation. Opinionated and narrow on purpose — it declares *intent*, never privilege.

```yaml
apiVersion: platform.grizzly.io/v1
kind: App
metadata:
  name: career-scanner
  namespace: career-scanner
spec:
  postgres:
    database: career-scanner          # role + DB named for the app; role owns the DB and nothing else
  s3:
    - bucket: career-scanner          # one userplus account, scoped to this bucket
      gateway: s3-bulk                 # s3-hot | s3-bulk
  valkey:
    enabled: true                      # one ACL user scoped to a key prefix
  sso:
    oidc:
      redirectURIs:
        - https://career-scanner.grizzly-endeavors.com/auth/callback
      scopes: [openid, email, profile] # allowlisted set only
status:
  postgres: { ready: true, secretRef: stores/career-scanner }
  s3:       { ready: true }
  valkey:   { ready: true }
  sso:      { ready: true, clientRef: stores/career-scanner }
  conditions: [...]
```

Design rules for the schema:

- **No privilege knobs.** There is no field for "make this role a superuser," "grant all buckets," "wildcard redirect," or "extra scopes beyond the allowlist." Each block is a fixed template with only the tenant-identifying values filled in. This is what makes "create-only" safe (see the sharp edge below).
- **Names are validated at admission** — DNS-1123, same rule the `register-app.yaml` workflow already enforces — via a Kyverno policy (or a CRD validation webhook) so a malformed or hostile name never reaches an actuator.
- **The CR lives in the app's namespace,** authored in the app repo. That is the trust boundary: the input is semi-trusted, so everything downstream treats it as untrusted.

## The additive-only capability model (the backbone)

The invariant across every controller: **create, never read existing state, never delete.** It cleanly divides responsibility — the controllers own *adding*; the operator stays the gatekeeper for *visibility* (read) and *teardown* (delete), which are the two directions where mistakes and compromise actually hurt.

Feasibility is not uniform. Per foundation:

| Foundation | Additive-only? | How |
|---|---|---|
| **1Password** | ❌ not decomposable | The original sketch rested on an OpenBao AppRole scoped `create`/`update` to `stores/<app>/*`. 1Password has no equivalent: a service account is scoped to a whole **vault**, its grants are immutable after creation, and `write_items` covers every item in it. Any controller that can write `stores-<app>` can rewrite `stores-postgres`. Options are a **vault per app** (many vaults, and the daily API cap is per *account*, shared across all of them) or routing writes through the same kind of **create-only broker** the versitygw row needs. Unresolved, and now the sharpest constraint on this design. |
| **Authentik** | ✅ clean (and it's the scariest foundation, so this is the happy result) | Service-account token scoped via RBAC to `add_oauth2provider` + `add_application` only — no `view`, `change`, or `delete`. |
| **Valkey** | ✅ achievable | Grant the controller `+acl\|setuser`, deny `+acl\|deluser`, `+@read`, `+@dangerous`. Creates ACL users; cannot delete them or read data. |
| **Postgres** | ⚠️ approximate — needs one extra step | A `CREATEROLE`+`CREATEDB` **non-superuser** (not the `postgres` superuser the Ansible play uses). No `CONNECT` on app DBs → no tenant-data read. **But** on PG16 a `CREATEROLE` role auto-gets `ADMIN` over roles it creates, so it retains standing to `SET ROLE` into every app. Fix: after creating each role, **`REVOKE` its own admin membership** over it. Idempotency without read: attempt the `CREATE` and catch "already exists" rather than checking first. Dropping superuser also removes the `COPY … TO PROGRAM` RCE vector. |
| **versitygw** | ❌ not decomposable | Creating a `userplus` account needs gateway **root**, and root is read + write + delete over every bucket. There is no add-only S3 credential. So the root cred lives behind a **minimal create-only broker** — a tiny service exposing only "create account + bucket from this template" — and the controller calls the broker. Root never lives in the general controller. |

## The two sharp edges

**1. "Create" includes "create a new privileged principal."** A provisioning controller mints credentials — it *sets* the password/key, so it inherently knows the creds it just created. "No read" stops it from stealing *existing* creds; it does nothing to stop a compromised controller from manufacturing a brand-new high-privilege account (a superuser-ish PG role, an `allcommands allkeys` Valkey user, a wide-open S3 account, a broadly-scoped OIDC client) and logging in through the front door with creds it legitimately generated. **Mitigation: template-constrained creates.** Because the `App` CR exposes no privilege knobs and each actuator only mints one fixed narrow shape, a compromised controller can only ever create *more of the same tenant-shaped thing* — never a wider principal. The template constraint is what actually closes this; "no read / no delete" alone does not.

**2. versitygw root is all-or-nothing.** Covered above — the create-only broker is the answer. The broker is the smallest possible attack surface (only additive ops, template baked in) and is the *only* thing holding S3 root; the general S3 controller holds nothing privileged on its own.

## Per-foundation actuator design

Each actuator does exactly what the operator does today, triggered by a reconcile instead of by hand.

- **Postgres actuator.** Connects as a `CREATEROLE`+`CREATEDB` role (its own 1Password-sourced cred, *not* superuser). Per `App.spec.postgres`: `CREATE ROLE <app> LOGIN PASSWORD <generated>` (catch-duplicate), `CREATE DATABASE <app> OWNER <app>` (catch-duplicate), then `REVOKE` its own admin over `<app>`. Writes `db_password` to `stores-<app>`. Name comes from the CR but is bound as an identifier through validated, allowlisted characters — never string-concatenated into SQL. Mirrors `setup-career-scanner-stores.yml`'s DB block.
- **S3 actuator + broker.** The actuator calls the broker: "create `userplus` account `<app>` + bucket `<bucket>` on `<gateway>`." The broker holds the gateway root cred, generates the access/secret pair, creates the account+bucket via the versitygw admin API, and writes `s3_access_key`/`s3_secret_key` to `stores-<app>`. The broker exposes no read/list/delete verb.
- **Valkey actuator.** `ACL SETUSER <app> on >…<generated> ~<app>:* +@all -@dangerous` (or a tighter command set), scoped to the app's key prefix. Writes the cred to `stores-<app>`. No `deluser`.
- **SSO actuator.** Creates the OAuth2 provider + bound application via the Authentik API using an `add_*`-only token, generating the `client_id`/`client_secret` and writing them to `stores-<app>` (or the platform authentik item). This **removes both current chokepoints**: no blueprint PR to grizzly-platform, and no `client_secret` injected into the shared worker's `global.env`. (Alternative delivery: keep blueprints but ship the app's blueprint as a labeled ConfigMap the worker discovers, with the secret still minted into 1Password — more moving parts than the API path, kept as a fallback.)
- **Secret writes** land in the 1Password item `stores-<app>`; the app's own ExternalSecret reads the same item under a read-scoped token — one source of truth, split read/write identities. Note the scoping caveat in the feasibility table: "write-scoped" is vault-wide, not per-item.

## Security / risk profile

The controllers are the most privileged thing in the cluster and are fed semi-trusted input (the `App` CR, authored in app repos). The honest threat model:

- **Worst case, per foundation, if a controller is compromised:** Postgres → cross-tenant data read/write/destroy (and, if it were superuser, host RCE — which is why it isn't); versitygw root → read/delete every bucket on a gateway; Authentik → mint rogue clients / tamper with identity (dominates any single data store); 1Password write → rewrite the creds apps pull, for *every* app in the vault rather than just its own (silent platform-wide takeover). Concentrated in one runtime this is total-platform compromise — which is exactly why the controllers are **split per foundation**, so a compromise is contained to one store.
- **Primary attack surface is the CR, not the pod.** The controller continuously parses attacker-influenceable input (`App` specs from app repos) into privileged actions. Injection is the concrete risk — e.g. a hostile `postgres.database` value into a `CREATE DATABASE` string. Closed by admission-time DNS-1123 validation + parameterized/allowlisted handling, never string interpolation.
- **The honest delta vs. today:** the god-creds already exist (Ansible vault + operator's head). The controllers don't invent privilege; they change it from *ephemeral, human-invoked, trusted-input* to *always-on, automated, network-reachable, semi-trusted-input, concentrated*. The upside is that every action becomes uniformly auditable, versus ad-hoc `docker exec`. Least-privilege is *less* enforceable than the original sketch assumed — see the 1Password row above.
- **Mitigations, ranked by leverage:** (1) split per foundation; (2) additive-only + de-escalated privilege (CREATEROLE not superuser; create-only broker for S3); (3) template-constrained creates; (4) a create-only secrets broker, since 1Password cannot scope a token below the vault; (5) NetworkPolicy pinning each controller to exactly its one foundation endpoint + kube-API; (6) provision-volume anomaly alerting into the existing Prometheus/Loki/ntfy path (mass provision = compromise signal); (7) the controller image ships through the gate + cosign + Kyverno admission ([ADR-028](../decisions/028-centralized-ci-gate.md)) like every other first-party image.
- **Residual risk you can't design away:** each controller still holds one foundation's provisioning cred, is network-reachable, and eats semi-trusted input. **Authentik is asymmetric** — identity compromise manufactures access *to* the apps in front of the data stores — so the SSO actuator gets the tightest token scope and is the one foundation where a **human gate on new-client creation** is worth keeping even in the self-service world. New databases are cheap and reversible; a new identity client is not.

## Build vs. buy

Two of the four foundations (versitygw, Authentik) have **no off-the-shelf Crossplane provider**, so their actuators are bespoke regardless. Once a versitygw broker and an Authentik reconciler are being written, the Postgres and Valkey actuators are ~20 lines each of the SQL/ACL that already exists in the Ansible plays. Running Crossplane *just* for Postgres while hand-writing the other half is more surface, not less — so the platform's own foundation choices tilt toward a **single bespoke operator per foundation**, which is also the more legible, more ADR-able, more "my system" path, and a natural fit for `kube-rs` (Rust) given the stack. `kro` (Kube Resource Orchestrator) could later sit on top to fan the `App` CR into sub-resources as composition sugar, but it still needs the actuators underneath — it's additive polish, not the foundation.

## Onboarding flow, end to end

1. App repo gains `platform/app.yaml` (the `App` CR) alongside its existing `deploy/` chart.
2. One-time: register the app's write-once Flux pointer in grizzly-platform (the evolution of today's `kubernetes/apps/<app>/` — a GitRepository + a single Kustomization pointing at the app repo, reconciled under a **namespace-scoped Flux ServiceAccount** so the app owns everything *inside* its namespace but nothing cluster-scoped).
3. `git push`. Flux applies the `App` CR; the controllers provision the foundations and mint creds into 1Password; the app's ExternalSecrets pull them; the workload comes up.
4. Subsequent foundation changes (a second bucket, a new redirect URI) are edits to `app.yaml` in the app repo — no grizzly-platform PR, no operator.

## Relationship to ADR-020 and the Flux shell

This composes with, and partly finishes, the "true ownership" thread. ADR-020 moved workloads to app repos; the parallel mechanical change is collapsing the per-app Flux plumbing (source/release/namespace) into a **write-once pointer + a namespace-scoped Flux SA**, so apps own their own rendering and namespace-internal resources safely. This provisioning control plane is the other half: it hands apps ownership of *foundation* resources without handing them the foundations' admin creds. The two are separable — the Flux-shell move is cheap and worth doing independently — but together they are what "apps truly own their platform resources" means.

## Lifecycle & decommission

- **Removed `App` CR → orphan-and-alert.** Controllers never cascade-delete foundation resources (no destroying a DB because a CR vanished or Flux pruned). Instead they emit an alert: "career-scanner's `App` CR is gone; its DB/bucket/client still exist; here is the decommission command." Teardown stays a separate, deliberate, human-gated action — consistent with the additive-only invariant.
- **Consequence:** a removed app leaves durable foundation state behind until the operator reaps it. Correct for this model, but decommission is not automatic and needs its own runbook when built.

## Open questions (the go/no-go and what's still undecided)

- **Build or not.** This is a real subsystem to own; the current eight apps don't need it. The bet is on scale + frontload, but the trigger to actually build (app count? a specific pain threshold?) isn't set.
- **The delete path.** Orphan-and-alert is decided; the *shape* of the eventual human-gated teardown (a separate low-frequency controller with delete creds? a one-shot Ansible play kept for teardown only?) is open.
- **Credential rotation.** The additive-only model mints once. Rotation is a deliberate, separate action — where does it live, and does it need read (to know current) or just overwrite?
- **The Authentik human-gate call.** Keep a manual approval on new OIDC clients, or trust the `add_*`-scoped token + template constraint fully?
- **Namespace, quota, and the scoped Flux SA** — are these part of the same `App` reconcile (the controller creates the namespace + ResourceQuota + LimitRange + SA/RBAC), or a separate step in the write-once pointer? Leaning: fold into the `App` CR so one resource onboards an app end to end.
- **Migrating the existing eight.** Backfilling `App` CRs for apps whose DBs/buckets/clients already exist means the actuators must adopt-not-recreate — which brushes against the no-read invariant (adoption implies knowing it exists). Likely handled by the same catch-duplicate path (attempt create, treat "exists" as adopted) without a general read grant.

## Graduation

If adopted: split into ADRs per committed piece (the `App` CR contract; the additive-only capability model already in [ADR-059](../decisions/059-app-self-service-provisioning.md); the per-foundation actuator + broker; the Flux-shell collapse), land the operator through the gate, write the operate + decommission runbooks, and migrate the eight existing apps last. Until then this stays here as the design of record.
