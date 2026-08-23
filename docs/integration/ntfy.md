# ntfy — push notifications from your app

Send a notification from any app to any subscriber (your phone, a browser, another service), and receive interactive taps back via action buttons. This is the consumer front door; operating ntfy (deploy, mint tokens, grant topics) is [runbooks/ntfy.md](../runbooks/ntfy.md); *why* it exists is [ADR-061](../decisions/061-ntfy-notification-service.md).

## 1. What you get

A **topic** on `https://ntfy.grizzly-endeavors.com`. Publish an HTTP request to `/<topic>` and every subscriber to that topic receives it — title, body, priority, tags, a tap-through link, and up to three action buttons that call back to your app. Topics are created implicitly on first publish; there's no registration, just an access grant.

## 2. When to use it (and when not)

- **Use it for:** operational alerts, human-in-the-loop approvals/confirmations, "something finished/failed" nudges, anything you'd otherwise want as a phone push.
- **Not for:** durable/must-not-lose events — ntfy delivery is best-effort with a short server-side cache, not a queue. Keep your own source of truth and use ntfy as the nudge (backfill missed messages with `?since=`). For work queues use [valkey.md](valkey.md); for machine-to-machine alerting that must page, layer on top of [observability.md](observability.md) alerts.

## 3. Prerequisites

- ntfy is deployed (it's core infrastructure — `kubernetes/infrastructure/ntfy/`). Confirm: `curl -s https://ntfy.grizzly-endeavors.com/v1/health` → `{"healthy":true}`.
- You can land a secret in your namespace via External Secrets — see [secrets.md](secrets.md) (every example below assumes it).
- A topic name. **Convention:** prefix with your app — `chores-approvals`, `myapp-alerts` — so grants stay scoped and topics don't collide. A topic name is semi-public to anyone granted it; never encode secrets in it.

## 4. Provision — a scoped token

The server is **`deny-all`**: nothing publishes or subscribes without a token, and each token is granted only the topics it needs. Mint one (operator step, full detail in the [runbook](../runbooks/ntfy.md)) and stash it in 1Password — never commit it:

```fish
set POD (kubectl -n ntfy get pod -l app.kubernetes.io/name=ntfy -o name)
kubectl -n ntfy exec $POD -- ntfy user add myapp            # a publisher identity
kubectl -n ntfy exec $POD -- ntfy access myapp 'myapp-alerts' rw   # grant just your topic(s)
kubectl -n ntfy exec $POD -- ntfy token add myapp           # prints tk_... — copy it
op item edit platform-ntfy --vault grizzly-platform myapp_token=tk_xxxxxxxx
```

## 5. Wire it up

**Land the token in your namespace** ([secrets.md](secrets.md) pattern — `ClusterSecretStore` `onepassword`):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ntfy-token
  namespace: myapp
spec:
  refreshPolicy: OnChange
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: ntfy-token
  data:
    - secretKey: token
      remoteRef:
        key: platform-ntfy/myapp_token
```

**Publish** — it's plain HTTP with a bearer token. Structured messages are cleanest as JSON to `/`:

```bash
curl https://ntfy.grizzly-endeavors.com \
  -H "Authorization: Bearer $NTFY_TOKEN" -H "Content-Type: application/json" \
  -d '{"topic":"myapp-alerts","title":"Deploy failed","message":"prod rolled back",
       "priority":4,"tags":["rotating_light"],"click":"https://grafana.grizzly-endeavors.com"}'
```

Priority is 1–5 (5 bypasses phone DND); tags matching [emoji shortcodes](https://docs.ntfy.sh/emojis/) render as icons. From code it's the same request — JS:

```ts
await fetch("https://ntfy.grizzly-endeavors.com", {
  method: "POST",
  headers: { Authorization: `Bearer ${process.env.NTFY_TOKEN}`, "Content-Type": "application/json" },
  body: JSON.stringify({ topic: "myapp-alerts", title: "Hi", message: "from my app" }),
});
```

**Action buttons** (the interactive case — an approval whose buttons POST back to *your* API). Up to 3 actions; `http` fires a request, `view` opens a URL:

```jsonc
{
  "topic": "chores-approvals",
  "title": "Approval needed",
  "message": "Alex submitted their checklist",
  "actions": [
    { "action": "http", "label": "Approve", "method": "POST",
      "url": "https://myapp.grizzly-endeavors.com/api/approve/123",
      "headers": { "Authorization": "Bearer <your-app-secret>" }, "clear": true },
    { "action": "http", "label": "Deny", "method": "POST",
      "url": "https://myapp.grizzly-endeavors.com/api/deny/123",
      "headers": { "Authorization": "Bearer <your-app-secret>" }, "clear": true }
  ]
}
```

Tapping **Approve** makes the phone POST straight to your app — no app UI round-trip. ntfy just relays the request, so authenticate your own callback (the button `headers` above).

**Subscribe.** A human uses the official ntfy phone/desktop app (add server `https://ntfy.grizzly-endeavors.com`, sign in with the username/token, subscribe to the topic) — that's what receives messages and renders the buttons. A service reacting to messages streams the topic as newline-delimited JSON, SSE, or WebSocket:

```bash
curl -H "Authorization: Bearer $NTFY_TOKEN" -sN \
     https://ntfy.grizzly-endeavors.com/myapp-alerts/json     # or /sse, or /ws
```

The ingress holds these streams open (read timeout 3600s); reconnect with backoff and use `?since=` to backfill.

## 6. Verify

```bash
# publish, with a subscriber (phone app or a `curl .../json` stream) watching the topic
curl -H "Authorization: Bearer $NTFY_TOKEN" -d "it works" https://ntfy.grizzly-endeavors.com/myapp-alerts
```

The subscriber should see "it works" within a second.

## 7. Troubleshoot

- **403 on publish/subscribe** → missing token, or the token isn't granted that topic. deny-all means *explicit grants only*: `ntfy access myapp` to check, `ntfy access myapp '<topic>' rw` to fix.
- **Subscription drops at ~60s** → your client bypassed the ingress or hit an intermediary with a short timeout; the platform ingress is set to 3600s. Reconnect with backoff + `?since=` regardless — streams aren't guaranteed permanent.
- **Action button "failed"** → your callback URL isn't reachable from the phone (must be a public `*.grizzly-endeavors.com` route), returned non-2xx, or rejected the button's auth header.
- **Messages you expected are missing** → best-effort delivery; a subscriber offline at publish time only gets cached messages (pull them with `?since=`). Don't rely on ntfy as a queue.

## 8. See also

- [runbooks/ntfy.md](../runbooks/ntfy.md) — operating ntfy: minting users/tokens, granting topics, health, backup.
- [secrets.md](secrets.md) — the 1Password → External Secrets pattern every example here uses.
- [ADR-061](../decisions/061-ntfy-notification-service.md) — why ntfy is a shared platform service.
- Upstream: [ntfy publish docs](https://docs.ntfy.sh/publish/) — the full header/JSON reference.
