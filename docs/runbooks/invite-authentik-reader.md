# Invite console — Authentik read-only group reader

The grizzly-invite provisioning console pulls its mint-form group chips **live from Authentik** instead of a hand-maintained list (chips = all groups minus `is_superuser` minus the denylist). To do that the broker calls `GET /api/v3/core/groups/` with a dedicated, least-privilege Authentik service account whose only power is listing groups.

Per [ADR-039](../decisions/039-authentik-social-federation-invitation-enrollment.md), identities and access grants live **inside Authentik, never in git** — so this reader (like admin promotion) is a documented bootstrap step, not a blueprint. Only the resulting API token is a secret, and it lives in 1Password (item `platform-invite`, field `authentik_api_token`), synced into the pod by External Secrets.

## What it provisions

- Service account user `grizzly-invite-reader` (`internal_service_account`).
- Role `grizzly-invite-reader-role` with the global `authentik_core.view_group` permission (authentik's forked guardian only assigns perms to Roles, not users).
- Group `grizzly-invite-readers` binding the role to the service account. This group is in the broker's `GROUP_DENYLIST` so it never appears as an invite chip.
- A non-expiring API token, stored in 1Password.

## Bootstrap (one-time, idempotent)

Requires the `operator` 1Password token (`OP_SERVICE_ACCOUNT_TOKEN`, the only one with write access) and `kubectl` reaching the `authentik` namespace. Re-running converges (uses `get_or_create`); it does not mint a second token.

```bash
export BAO_ADDR=https://10.0.0.200:8200
OUT=$(kubectl -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.rbac.models import Role
from authentik.core.models import Group, User, Token, TokenIntents, UserTypes
from guardian.shortcuts import assign_perm, get_objects_for_user
u,_=User.objects.get_or_create(username='grizzly-invite-reader', defaults={'name':'Grizzly Invite group reader','type':UserTypes.INTERNAL_SERVICE_ACCOUNT,'path':'goauthentik.io/user/service-accounts'})
u.is_active=True; u.type=UserTypes.INTERNAL_SERVICE_ACCOUNT; u.save()
role,_=Role.objects.get_or_create(name='grizzly-invite-reader-role')
assign_perm('authentik_core.view_group', role)
g,_=Group.objects.get_or_create(name='grizzly-invite-readers')
role.groups.add(g)
u.ak_groups.add(g)
u=User.objects.get(username='grizzly-invite-reader')
t,_=Token.objects.get_or_create(identifier='grizzly-invite-reader-api', defaults={'user':u,'intent':TokenIntents.INTENT_API,'expiring':False,'description':'Read-only groups list for the invite provisioning console'})
print('GRIZZLYKEY:'+t.key)
print('GRIZZLYSEES:'+str(get_objects_for_user(u,'authentik_core.view_group').count()))
" 2>/dev/null)
KEY=$(printf '%s\n' "$OUT" | grep '^GRIZZLYKEY:' | cut -d: -f2-)
SEES=$(printf '%s\n' "$OUT" | grep '^GRIZZLYSEES:' | cut -d: -f2-)
[ -n "$KEY" ] || { echo "failed to mint token"; exit 1; }
echo "reader can view $SEES groups"
op item edit platform-invite --vault grizzly-platform "authentik_api_token=$KEY"
```

`$SEES` should equal the total group count (the reader sees every group). The `KEY` is never echoed — it goes straight into 1Password.

**Order matters:** run this *before* deploying the chart that adds the `authentik_api_token` key to the invite ExternalSecret. An ExternalSecret fails as a whole if any referenced property is missing, so merging the chart change first would break the pod's secret sync.

## Verify end-to-end (after deploy)

```bash
kubectl -n grizzly-invite logs deploy/grizzly-invite | grep -i authentik   # no "failed to refresh" warnings
# Or, from the admin console (grizzly-admins), the mint form's chips should
# match the live membership groups, including any added since.
```

If the token is unset/unreachable the broker logs a warning and serves the static fallback list (`adminUi.groups`) — the form still works.

## Rotate

```bash
kubectl -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.core.models import Token
t=Token.objects.get(identifier='grizzly-invite-reader-api'); t.key=Token().key; t.save(); print('NEWKEY:'+t.key)"
# capture NEWKEY, then: op item edit platform-invite --vault grizzly-platform authentik_api_token=<newkey>
```

ESO resyncs within its refresh interval (1h); delete the pod to pick it up immediately.

## Teardown

```bash
kubectl -n authentik exec deploy/authentik-server -- ak shell -c "
from authentik.core.models import User, Group
from authentik.rbac.models import Role
User.objects.filter(username='grizzly-invite-reader').delete()
Role.objects.filter(name='grizzly-invite-reader-role').delete()
Group.objects.filter(name='grizzly-invite-readers').delete()"
```
