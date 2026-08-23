# Integration: SSO (Authentik)

**What you get:** your app's login delegated to Authentik, the central IdP — one account per person across every platform app, gated by invitation. Two integration paths depending on whether your app speaks OIDC.

- **OIDC** (preferred) — your app is an OAuth2/OpenID Connect client; Authentik handles the login and hands back tokens. Use this whenever your app or its framework supports OIDC.
- **Forward-auth proxy** — for apps with no auth of their own (dashboards, internal tools). ingress-nginx asks Authentik "is this request authenticated?" before it ever reaches your app. No app code required. Reference: the invite admin UI ([ADR-043](../decisions/043-invite-admin-ui-forward-auth.md)).

Config is **blueprints** — declarative config-as-code applied by the Authentik worker and reconciled every 60 min ([ADR-037](../decisions/037-authentik-config-as-code-blueprints.md)). You add a file under `kubernetes/infrastructure/authentik/blueprints/`. **Read [`blueprints/CLAUDE.md`](../../kubernetes/infrastructure/authentik/blueprints/CLAUDE.md) before editing** — the `!KeyOf` ordering rule and the "removal means deletion, not omission" rule will bite you otherwise.

## Path A — OIDC client

Model on [`blueprints/career-scanner.yaml`](../../kubernetes/infrastructure/authentik/blueprints/career-scanner.yaml). It registers two objects in one file: an `oauth2provider` and the `application` bound to it.

### 1 — Store the client credentials in 1Password

The `client_id`/`client_secret` are the OIDC contract shared by **both** sides, so they get one source of truth: two fields on the `platform-authentik` item in the `grizzly-platform` vault. Generate them so the values never echo:

```bash
OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/op-tokens/operator)" \
  op item edit platform-authentik --vault grizzly-platform \
  "oidc_<app>_client_id[password]=$(openssl rand -hex 16)" \
  "oidc_<app>_client_secret[password]=$(openssl rand -base64 48)" > /dev/null
```

They are injected into the Authentik worker (which applies blueprints) via `global.env` as `AUTHENTIK_<APP>_CLIENT_ID` / `_SECRET`, sourced by the authentik `ExternalSecret`. **Never put them in the blueprint literally** — the blueprint reads them with `!Env`.

### 2 — Add the blueprint

```yaml
version: 1
metadata:
  name: grizzly-<app>-oidc
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: <app>-provider
    identifiers: { name: <app> }
    attrs:
      client_type: confidential
      client_id: !Env [AUTHENTIK_<APP>_CLIENT_ID, ""]
      client_secret: !Env [AUTHENTIK_<APP>_CLIENT_SECRET, ""]
      # REQUIRED since Authentik 2026.x — without it grant_types is [] and the
      # authorize endpoint rejects every code request as "invalid_request".
      grant_types: [authorization_code, refresh_token]
      redirect_uris:
        - matching_mode: strict
          url: https://<app>.grizzly-endeavors.com/auth/callback
      sub_mode: hashed_user_id
      include_claims_in_id_token: true
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-explicit-consent]]
      invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      signing_key: !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [scope_name, openid]]
        - !Find [authentik_providers_oauth2.scopemapping, [scope_name, email]]
        - !Find [authentik_providers_oauth2.scopemapping, [scope_name, profile]]
  - model: authentik_core.application
    identifiers: { slug: <app> }
    attrs:
      name: <app>
      provider: !KeyOf <app>-provider     # same-file reference — provider must be above
      meta_launch_url: https://<app>.grizzly-endeavors.com
      policy_engine_mode: any
```

Register the file in the authentik `kustomization.yaml`/`blueprints.configMaps` and commit. Flux applies it; Authentik reconciles within 60 min (or restart the worker to force it).

### 3 — Configure your app as the client

Land the same two keys in your app's namespace via its own `ExternalSecret` (from the *same* 1Password item — one source of truth), then point your OIDC library at Authentik's discovery doc:

```
issuer:        https://sso.grizzly-endeavors.com/application/o/<app>/
client_id:     ${OIDC_CLIENT_ID}
client_secret: ${OIDC_CLIENT_SECRET}
redirect_uri:  https://<app>.grizzly-endeavors.com/auth/callback
scopes:        openid email profile
```

Use the authorization-code flow (with PKCE). The well-known config lives at `<issuer>.well-known/openid-configuration`.

## Path B — Forward-auth proxy (no OIDC in the app)

Add a **proxy provider** (forward-auth mode) + application blueprint, bind it to the shared Authentik outpost, and put these annotations on your app's Ingress so ingress-nginx enforces auth upstream:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-url: "https://sso.grizzly-endeavors.com/outpost.goauthentik.io/auth/nginx"
    nginx.ingress.kubernetes.io/auth-signin: "https://sso.grizzly-endeavors.com/outpost.goauthentik.io/start?rd=$escaped_request_uri"
    nginx.ingress.kubernetes.io/auth-response-headers: "Set-Cookie,X-authentik-username,X-authentik-email,X-authentik-groups"
```

Your app then trusts the `X-authentik-*` headers for identity. See the invite-admin-ui setup ([ADR-043](../decisions/043-invite-admin-ui-forward-auth.md)) for the working example.

## Onboarding people & scoping access

Users are **not** blueprint objects — no human PII lands in this public repo. Identity comes from the social provider (Discord/GitHub/Google) at first login, or from the address someone enters in the email sign-up flow, and access is **closed, gated by invitation** on both paths ([ADR-040](../decisions/040-invite-broker-cookie-bridged-enrollment.md), [ADR-066](../decisions/066-email-otp-passwordless-signin.md)).

- **Invite someone:** mint an invite on the broker (`POST /api/invites` with the admin bearer token) and send them the `invite.grizzly-endeavors.com/i/<token>` link. They click, then either sign in with a social provider or use **Sign up** to enroll with an email address and the one-time code they are sent. Either way they land in `grizzly-users`.
- **Two credential shapes:** social enrollees sign in with their provider; email enrollees have no password at all and get a fresh code each time. Your app sees the same OIDC/forward-auth identity either way — don't assume a password exists anywhere.
- **Pre-scope into a group:** pass `{"groups": ["<group>"]}` in the mint body (groups from `blueprints/groups.yaml`).
- **Gate your app to a subset:** either restrict app *visibility* by group policy binding ([ADR-049](../decisions/049-app-visibility-scoped-via-group-policy-bindings.md)), or add a `groups` scope mapping + check the claim in-app (modeled on `blueprints/nextcloud.yaml`). By default any enrolled `grizzly-users` member can use an app.

## Verify

```bash
# Discovery doc resolves and lists your client's endpoints:
curl -s https://sso.grizzly-endeavors.com/application/o/<app>/.well-known/openid-configuration | jq .issuer
```

Then drive a real login end-to-end in a browser: hit your app, get bounced to Authentik, sign in, land back on the callback authenticated.

## Troubleshoot

- **`invalid_request` at the authorize endpoint / SSO never completes** — missing `grant_types` on the provider (Authentik 2026.x makes them explicit). Add `[authorization_code, refresh_token]`.
- **`redirect_uri` mismatch** — `matching_mode: strict` means the URL must match byte-for-byte, including scheme and trailing path. Fix the blueprint or the app config so they're identical.
- **Blueprint won't apply / `KeyOf: failed to find entry`** — a `!KeyOf` reference points at an entry *below* it in the file. Order dependencies-first: provider above application. Cross-file references must use `!Find`, not `!KeyOf`.
- **Removed a client but it still works** — blueprints are stateless upsert; deleting the file doesn't delete the object. Mark it `state: absent`, let one reconcile delete it, then drop the file (see `blueprints/CLAUDE.md`).
- **Client secret rejected** — the app and the blueprint are reading different values. Both must source the *same* `platform-authentik` fields.
- **Sign-up code never arrives** — the email enrollment path depends on the mail plant. See [authentik-email-otp.md](../runbooks/authentik-email-otp.md).

## See also

- [`blueprints/CLAUDE.md`](../../kubernetes/infrastructure/authentik/blueprints/CLAUDE.md) — the blueprint authoring rules. Non-negotiable reading.
- [invite-authentik-reader.md](../runbooks/invite-authentik-reader.md) — the read-only group reader behind the invite console.
- [secrets.md](secrets.md) — landing the client credentials.
- ADR [033](../decisions/033-central-identity-authentik.md), [037](../decisions/037-authentik-config-as-code-blueprints.md), [039](../decisions/039-authentik-social-federation-invitation-enrollment.md)–[043](../decisions/043-invite-admin-ui-forward-auth.md), [049](../decisions/049-app-visibility-scoped-via-group-policy-bindings.md).
