# Inference platform: LiteLLM + Langfuse + LibreChat, onboarding as code

**Date:** 2026-08-23
**Status:** Exploring — scoped and empirically tested in a sandbox (`~/Projects/playground/inference/`, disposable). Not built on the platform. Calibrated for a several-hundred-user enterprise deployment, not the homelab.

## The question

Can LiteLLM (gateway), Langfuse (LLM observability) and LibreChat (chat UI) be run as one self-hosted inference platform where *everything that recurs* — a new person, a new team, a new model, a budget change, a key rotation — happens on its own or from one command, with no chain of UI clicks across three admin panels?

**Short answer: yes, to roughly 95% on the free/OSS builds**, with one sync job doing the repetitive work and two items that stay manual (or need an enterprise license). Everything in the "verified" tables below was exercised against real instances: LiteLLM v1.98.0, Langfuse v3.225.4 OSS, LibreChat v0.8.7, Keycloak 26.3 standing in for Authentik.

## The model that makes it automatable

The trick is to let **the IdP be the only place a human assigns anything**, and make every system downstream derive its state from IdP groups:

```
IdP group  "team-research"
   │
   ├─ LibreChat   role "team-research"        ← OPENID_ROLE_SYNC (on every login)
   │     └─ role-scoped config override      ← Admin API (sync job)
   │           endpoint "Gateway" w/ team key
   │
   ├─ LiteLLM     team "team-research"        ← /team/new|update (sync job)
   │     ├─ models: access group(s)
   │     ├─ budget + reset interval
   │     ├─ team virtual key (used by LibreChat for that role)
   │     └─ team → Langfuse project callback  ← /team/{id}/callback (sync job)
   │
   └─ Langfuse    org "Team Research"         ← tRPC (sync job)
         ├─ project + key pair
         └─ members by email (direct if user exists, invite otherwise)
```

Per request, LibreChat forwards `x-litellm-end-user-id: <email>` and `x-litellm-session-id: <conversation id>`; LiteLLM upserts the end user, records spend against *person + team + model + tags*, and Langfuse receives the trace with `userId`, `sessionId` and cost already filled in.

So the recurring operations collapse to:

| Event | Who acts | What happens |
|---|---|---|
| New hire | IdP admin adds them to a group | First login provisions the user in all three apps with the right role/team/org. Zero admin clicks. |
| New team | Add a group in the IdP **and** one entry in `teams.yaml` | Sync job creates LiteLLM team+key+callback, Langfuse org+project+keys, LibreChat role+override. |
| Budget / model access change | Edit `teams.yaml`, merge | Sync job reconciles. |
| New model / provider | Edit LiteLLM `config.yaml` (`model_list`), merge | Rollout. LibreChat picks it up via `models.fetch: true` — no LibreChat change. |
| Offboarding | Remove from IdP | Login stops everywhere immediately (SSO-only). LiteLLM *access* stops because the only key is the team key held by LibreChat, not the person. |
| Key rotation | Sync job, scheduled | LiteLLM `/key/regenerate` → push new key into LibreChat role override. |

## What was verified (sandbox, real APIs)

### LiteLLM (free tier)

| Capability | Result |
|---|---|
| `model_list`, callbacks, access groups in `config.yaml` | ✅ Config-as-code. Mock models need no provider keys. |
| Teams with budget, reset interval, model access groups | ✅ `/team/new`. Access-group denial returns a clean 403 (`team_model_access_denied`). |
| Virtual keys with fixed value (so GitOps can hold them) | ✅ `/key/generate` accepts `"key": "..."` (≥16 chars). |
| End-user attribution from a header alone | ✅ `x-litellm-end-user-id` → end user auto-upserted with spend; `/customer/info` works. Body `user` field also works (LibreChat sends its Mongo id there; header wins when both present). |
| Per-team Langfuse project routing | ✅ `POST /team/{id}/callback` with that team's Langfuse keys; traces landed in the team project only. |
| Tags → spend logs | ✅ `x-litellm-tags` arrives on spend logs and Langfuse tags. |
| `/v1/models` filtered by the caller's access | ✅ A team key sees only its models — this is what gives LibreChat per-team model menus for free. |
| Cost headers | ✅ `x-litellm-response-cost*` on every response. |
| Idempotency | ❌ `/team/new`, `/user/new` are create-only (400/409 on repeat). A reconciler must `GET → create or update`. No declarative sync exists. |
| Prometheus `/metrics` | ✅ free (per docs; not exercised). |

**Enterprise-gated in LiteLLM:** SCIM, JWT-claim → team auto-assignment, admin-UI SSO beyond 5 users, tag budgets, wildcard model access. None are needed under the model above — the admin UI is not on the human path, and team assignment is done by the sync job from the IdP.

### Langfuse (OSS)

| Capability | Result |
|---|---|
| Headless init (one org, one project, fixed key pair, first user) | ✅ `LANGFUSE_INIT_*`. LiteLLM could trace from first boot with no UI. |
| SSO auto-join | ✅ `LANGFUSE_DEFAULT_ORG_ID/_ROLE` — first login lands in the org with no admin action. |
| Create additional projects + key pairs headlessly | ✅ **via the UI's tRPC** (`projects.create`, `projectApiKeys.create`) with a scripted NextAuth credentials login. Unversioned internal API — pin the image and re-test on upgrade. The *documented* API for this is enterprise-only. |
| Create orgs + add members by email headlessly | ✅ tRPC `organizations.create`, `members.create`. Existing user → added immediately; unknown email → pending invitation, **consumed automatically on first SSO login** (verified). |
| Project-level access scoping inside one org | ❌ EE only. In OSS every org member sees every project. **Therefore: one org per team**, not one org with many projects. |
| Restrict who can create orgs | ❌ EE ("Organization Creators"). Any user can click *New Organization*. Harmless but untidy. |
| Cost on traces from LiteLLM | ✅ ingested cost wins over Langfuse's price table. |
| Metrics API grouped by user | ⚠️ `/api/public/v2/metrics` can't group by `userId`; per-person chargeback comes from LiteLLM spend logs instead (which is the better source anyway). |

Other EE-only items, for completeness: SCIM, audit log UI, data-retention policies, protected prompt labels. IdP-group → role mapping does not exist in any tier; the sync job covers it.

### LibreChat (free; it has no paid tier)

| Capability | Result |
|---|---|
| SSO-only login (no local accounts, no self-registration form) | ✅ `ALLOW_EMAIL_LOGIN=false`, `ALLOW_REGISTRATION=false`, `ALLOW_SOCIAL_REGISTRATION=true`. Login page shows only the IdP button. |
| OIDC claim → ADMIN | ✅ `OPENID_ADMIN_ROLE=admin` + `..._PARAMETER_PATH=groups`. |
| OIDC claim → custom role (team) | ✅ `OPENID_ROLE_SYNC_*` (undocumented in the main docs; present in 0.8.7). Picks the highest-priority matching claim value. **The roles must already exist** or login fails — the sync job creates them first. |
| Per-role config overrides (the team key trick) | ✅ `PUT /api/admin/config/role/<role>` with `overrides.endpoints.custom[...]`. Alice's model menu changed to the team's allowed set and her traffic carried `team_id=team-research`. DB-backed, survives restarts. |
| Identity forwarding to the gateway | ✅ `headers:` with `{{LIBRECHAT_USER_EMAIL}}`, `{{LIBRECHAT_BODY_CONVERSATIONID}}`. Headers are also sent on the `/v1/models` fetch. |
| `{{LIBRECHAT_OPENID_GROUPS}}` | ❌ not resolved in 0.8.7 (literal string forwarded), even with `OPENID_REUSE_TOKENS`. Not needed under the role-override model. |
| Model list from gateway | ✅ `models.fetch: true`. |
| Pre-built assistants (`modelSpecs`) | ✅ YAML. |
| Admin REST API | ✅ `/api/admin/{users,roles,groups,grants,config,skills,audit-log}`. Needs an ADMIN JWT; obtainable headlessly only through an IdP login (service-account flow not built in — see gaps). |
| Roles bootstrap | Seeded by direct Mongo upsert in the sandbox (a copy of the `USER` document). Production: same, or via `/api/admin/roles` once an admin token exists. |
| Agents / presets seeding | ❌ no YAML seeding for individual agents; Agents API is beta. Shared "golden" agents are one-time admin work, then referenced from `modelSpecs`. |
| Infra | MongoDB is mandatory (no Postgres option). Meilisearch optional. RAG needs its own pgvector Postgres + `rag_api` service. Files → S3. Redis required for >1 replica. |

### Sandbox-only findings (won't apply on the platform)

- Langfuse's generic `AUTH_CUSTOM_*` provider rejects Keycloak's `refresh_expires_in`; the dedicated `AUTH_KEYCLOAK_*` provider works. Authentik already works with `AUTH_CUSTOM_*` (ADR-064).
- LibreChat's `openid-client` refuses a plain-HTTP issuer and sets a `Secure` session cookie by default (`SESSION_COOKIE_SECURE=false` to override). Moot behind TLS.

## The sync job — what "one button" actually is

A single reconciler, run on merge and on a schedule (and re-runnable at any time), with one input file:

```yaml
# teams.yaml
- id: team-research
  idp_group: team-research
  models: [restricted]          # LiteLLM access groups
  budget: { max: 500, reset: 30d }
  admins: [lead@acme.test]      # Langfuse org ADMIN; everyone else MEMBER
```

Per team it ensures (all idempotent, all verified individually above):

1. **LiteLLM** — team exists with these models/budget; team key exists (`sk-team-<id>-<n>`); team callback points at the team's Langfuse keys.
2. **Langfuse** — org exists; project exists; key pair exists (stored in 1Password); members = IdP group members by email (direct or invitation).
3. **LibreChat** — role exists; role config override carries the team key on the gateway endpoint.
4. **Membership reconciliation** — reads IdP group members (Authentik API), upserts LiteLLM `/user` + team membership (for spend roll-ups), and Langfuse org membership. LibreChat needs nothing: role sync happens at login.

Secrets stay in 1Password; the job reads a LiteLLM master key, a Langfuse bootstrap login, and a LibreChat admin credential from it.

## What stays manual or imperfect

1. **LibreChat admin token for the sync job.** The admin API wants a JWT from a logged-in ADMIN. Options: (a) keep `ALLOW_EMAIL_LOGIN=true` for exactly one bot account whose password lives in 1Password and obtain the JWT via `POST /api/auth/login` — no SSO bypass for anyone else since registration is off; (b) write role overrides straight into Mongo (`configs` collection) the way roles were seeded. (a) is cleaner. Untested.
2. **Langfuse tRPC is unversioned.** Works today; must be re-verified at each pinned image bump. The alternative is the EE licence (Instance Management API, project RBAC, SCIM), which also collapses org-per-team back into one org with scoped projects.
3. **Anything a user can create inside an app** (agents, prompts, presets, Langfuse dashboards) is per-user state; "golden" shared versions are created once by an admin and shared — not recurring, but not code either.
4. **LiteLLM admin UI SSO** is capped at 5 users on the free tier. Fine if the UI is an operator tool, not a user tool.
5. **Offboarding cleanup** — the person's data stays in each app after IdP removal. Deleting it is a sync-job extension (LibreChat `/api/admin/users`, LiteLLM `/user/delete`, Langfuse tRPC), not a blocker.

## Production shape (not built)

- **Deploy:** three Helm charts (LiteLLM `oci://ghcr.io/berriai/litellm/chart/litellm`, Langfuse, LibreChat `oci://ghcr.io/danny-avila/librechat-chart/librechat`) under Flux, each with its bundled stores disabled and pointed at foundation stores per ADR-003 — Postgres (LiteLLM, Langfuse, RAG/pgvector), Valkey (LiteLLM routing/rate-limits, LibreChat multi-replica, Langfuse queue), ClickHouse (Langfuse), versitygw (Langfuse events/media, LibreChat files). **MongoDB is the one new store** LibreChat forces; it would be a sixth foundation store on the R730xd, not an in-cluster PVC.
- **HA:** LiteLLM ≥2 replicas + Redis + a separate migration Job (`DISABLE_SCHEMA_UPDATE=true` on the proxies); LibreChat ≥2 replicas + Redis + shared JWT/CREDS secrets; Langfuse web+worker already split.
- **Observability:** LiteLLM `/metrics` (free) into Prometheus; LibreChat `/metrics` with `METRICS_SECRET`; Langfuse is itself the LLM-level view. Alerts: team budget remaining (`litellm_remaining_team_budget_metric`), gateway error rate, ClickHouse insert lag (exists).
- **Sync job:** a small CLI (Python, `httpx`) in a CronJob + Argo Workflow on merge of `teams.yaml`. ~400 lines. This is the only new code.
- **Sizing hint from upstream for this user count:** LiteLLM 1 vCPU / 4 GiB per pod minimum; Redis in-cluster-adjacent; nothing exotic.

## Control plane instead of files

`teams.yaml` was only the cheapest single source of truth. The same sync logic becomes a **control-plane service** with its own Postgres (desired state + audit log), a web UI in front, and the reconciler behind — git is not in the loop.

- **Objects:** Teams (IdP group, budget, model tiers, admins, retention), Model catalog (replaces `model_list`; reconciler writes LiteLLM's DB via `STORE_MODEL_IN_DB`), Assistants (pushed as LibreChat `modelSpecs` role overrides). Plus Activity (audit, reconciler runs, drift) and Requests (approvals).
- **Why a DB, not git:** audit is a table the UI shows; approvals are a state machine (`pending → approved → applied`); drift against the live apps is recorded and re-appliable; policy (caps, allowed tiers) lives in the service so team leads can self-serve; keys are minted and pushed by the service and never handled by a human. YAML is an export for DR/seed only.
- **Two adapters, one codebase:** enterprise (SCIM does membership; Langfuse Instance Management API; project-level RBAC → one org, scoped projects) and OSS (reconciler does membership; Langfuse tRPC; org-per-team). The OSS build is the home test bed for the enterprise one.
- **Door policy:** the per-app admin UIs stay reachable as break-glass for platform admins only; everyone else goes through the control plane, or drift becomes normal.

## Decision needed before building

Whether to stay OSS with the tRPC dependency and org-per-team, or buy Langfuse EE for the supported API + project RBAC + SCIM. Everything else is settled by the tests above. If OSS: write the sync job first, since it is the piece that turns three admin panels into one file.
