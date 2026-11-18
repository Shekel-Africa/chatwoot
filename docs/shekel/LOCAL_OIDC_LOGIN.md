# Local dev: staff sign-in through authentication-api (OIDC, admin realm)

This is the Shekel fork of Chatwoot (`Shekel-Africa/chatwoot`, branch `shekel/main`).
Staff sign in with their authentication-api **admin** account. The design is in
`docs/superpowers/specs/2026-11-17-shailoq-agent-gateway-design.md` (sections 4.2 and 6.2)
in the Shekel docs repo.

## Community build only

We use the MIT core only. Never enable anything under `enterprise/` (proprietary, paid per
seat; it includes SAML/SSO, custom roles, audit logs, SLA, Captain).

- Upstream's switch is the `DISABLE_ENTERPRISE` environment variable
  (`ChatwootApp.enterprise?` in `lib/chatwoot_app.rb`). When it is set, the `enterprise/`
  overlays (`prepend_mod_with`, `enterprise/app/**` behaviour) are not loaded.
- `ENV.fetch('DISABLE_ENTERPRISE', false)` treats **any** value as "disabled", including
  the string `false`. Set it to `true` and never to anything else.
- The `enterprise/` files are still in the local tree (eager-load paths), only inert. The
  image built from `docker/Dockerfile` deletes them (`rm -rf enterprise spec/enterprise`,
  as upstream's CE build does) and sets `DISABLE_ENTERPRISE=true CW_EDITION=ce`.

## Run it

Prerequisites: Docker. Everything runs in containers; no host Ruby or Node is needed.

```sh
W=/mnt/nas/code/shekel/chatwoot/shekel-main
DC="docker compose --project-directory $W -f $W/docker-compose.yaml -f $W/docker-compose.shekel.yaml"

$DC build                                   # first time only, slow
$DC run --rm rails bundle exec rails db:chatwoot_prepare
$DC up -d rails                             # also starts postgres, redis, vite, sidekiq, mailhog
```

Open http://localhost:3000. If the browser is not on the NAS, forward port 3000 (and 3036
for Vite) so the URL is still `localhost:3000`: the redirect URI is exact-match.

`docker-compose.shekel.yaml` gives the stack its own project name (`cw-shekel-dev`) and
moves Postgres, Redis and Mailhog to loopback ports 55432, 56379 and 58025, because the
shared dev host already uses 6379, 1025 and 8025.

### Create the account staff are provisioned into

Staff are provisioned on their first Shekel sign-in into one account, set by
`SHEKEL_CHATWOOT_ACCOUNT_ID`. Create it through the onboarding screen, or from a console:

```sh
$DC run --rm rails bundle exec rails runner 'puts Account.create!(name: "Shekel Local").id'
```

### Map tenants to teams

Staff join the team mapped from each tenant in their `tenants` claim:

```sh
$DC run --rm rails bundle exec rails "shekel:map_tenant_team[<tenant uuid>,Acme Motors]"  # creates the team if missing
$DC run --rm rails bundle exec rails shekel:list_tenant_teams
```

## Environment variables

All go in the worktree's `.env` (gitignored; on the NAS it is a hardlink to
`/mnt/nas/code/shekel/chatwoot/.wt-shared/.env`). Never commit values.

| Variable | Meaning |
|---|---|
| `DISABLE_ENTERPRISE` | `true`. Community build only. |
| `FRONTEND_URL` | `http://localhost:3000` locally. |
| `SHEKEL_OIDC_CLIENT_ID` | Admin-realm OAuth client id. Setting it shows the "Sign in with Shekel" button. |
| `SHEKEL_OIDC_CLIENT_SECRET` | That client's secret. |
| `SHEKEL_OIDC_ISSUER` | Admin-realm issuer: `https://auth.shekel.africa/oauth/admin` on staging. Checked against the ID token's `iss`. |
| `SHEKEL_OIDC_REDIRECT_URI` | `http://localhost:3000/omniauth/shekel/callback` locally. Must equal the registered redirect URI. |
| `SHEKEL_OIDC_AUTHORIZE_URL` | `<host>/oauth/admin/authorize` |
| `SHEKEL_OIDC_TOKEN_URL` | `<host>/oauth/admin/token` |
| `SHEKEL_OIDC_USERINFO_URL` | `<host>/oauth/admin/userinfo` |
| `SHEKEL_OIDC_JWKS_URL` | `<host>/oauth/jwks` (shared by both realms) |
| `SHEKEL_CHATWOOT_ACCOUNT_ID` | Required for sign-in. The account staff are provisioned into. **Setting it turns staff mode on** (`Shekel::OidcSettings.staff_mode?`): team-scoped visibility, Shekel as the only sign-in (no password, Google or SAML), no personal API tokens and the short session. Leave it unset to use upstream Chatwoot locally. |
| `SHEKEL_SESSION_LIFESPAN_HOURS` | Optional, default `12`. How long a staff session lasts in staff mode (devise_token_auth `token_lifespan`). Read at boot. |
| `SHEKEL_API_USER_IDS` | Optional, comma-separated user ids whose personal API token still works in staff mode (the Shailoq gateway's administrator service user). |
| `SHEKEL_STAFF_HOSTS`, `SHEKEL_PUBLIC_HOST` | Optional locally (both unset leaves the host guard off). See [OPERATIONS.md](OPERATIONS.md#environment-variables). |
| `SHEKEL_OIDC_DISCOVERY` | Optional. `true` reads the four URLs from `<issuer>/.well-known/openid-configuration` instead. Leave it off on staging until the nginx fix below is in. |

`<host>` is `https://auth.shekel.africa` on staging. The endpoint paths come from
authentication-api (`routes/oauth.php`, `routes/oauth-protocol.php`,
`OAuthRealmRoutes::issuer()`, `OIDCController::discovery()`).

## How it works

- `config/initializers/omniauth.rb` mounts an `omniauth_openid_connect` strategy named
  `shekel`. Its settings are read from `SHEKEL_OIDC_*` per request by
  `Shekel::OidcSettings` (`app/services/shekel/oidc_settings.rb`): authorization code flow,
  PKCE (S256), state, nonce, `client_secret_basic`, scopes
  `openid email profile tenants customer_comms.access customer_comms.admin`. The ID
  token is verified against the JWKS for signature (RS256 only, pinned with
  `client_signing_alg`), issuer, audience and nonce. `realm` is read from the merged
  ID-token + userinfo claims (`extra.raw_info`); the ID-token value wins.
- The button (`app/javascript/v3/components/ShekelOidc/Button.vue`) POSTs to
  `/omniauth/shekel` with the Rails CSRF token (OmniAuth refuses a GET request phase).
- The callback goes through upstream's `DeviseOverrides::OmniauthCallbacksController`, which
  hands off to `ShekelOidcSignIn` (`app/controllers/concerns/shekel_oidc_sign_in.rb`):
  - the `realm` claim must be `admin` (a customer-realm token, or one with no `realm`, is
    refused even if the email matches an agent). This is checked on the first callback hop
    (`redirect_callbacks`), because devise_token_auth drops `extra` (the ID-token claims)
    from the auth hash it carries to the second hop; a one-shot session flag passes the
    result on, together with the `sub`, the tenant ids from the `tenants` claim that are
    mapped to a team (only those, so the cookie session stays small), whether the claim
    was present, and whether the token response's `scope` (`credentials.scope`) grants
    `customer_comms.admin`;
  - in staff mode every other OmniAuth provider (Google) is refused at both hops;
  - `Shekel::StaffSync` (`app/services/shekel/staff_sync.rb`) then provisions and syncs
    the staff member: finds the user by the IdP `sub` (stored as `custom_attributes.shekel_sub`),
    then by email, and follows an email change at the IdP (same Chatwoot user, new email,
    unless another user already holds it). **A user who already exists with the same email
    (created by hand, or before Shekel sign-in) is adopted on their first Shekel sign-in**:
    linked to the `sub`, confirmed, and given the role and teams of the claims. It creates
    the user if neither matches (random password, confirmed), sets the role (administrator with `customer_comms.admin`, else agent),
    joins the teams mapped from held tenants and leaves mapped teams for tenants no
    longer held (unmapped teams are untouched), and adds them to every inbox. If the
    `tenants` claim is absent (an older IdP), team membership is left as it is and a
    warning is logged; an explicit empty list removes them from all mapped teams. It also
    rotates their personal API token;
  - the user signs in through upstream's SSO-token path, with a token marked as issued by
    Shekel sign-in (`Shekel::SsoTokens`).
- In staff mode (`SHEKEL_CHATWOOT_ACCOUNT_ID` set), password sign-in, password reset and the
  profile password change are refused ("Sign in with Shekel instead.",
  `ShekelPasswordLoginGuard`), and so is any SSO token not issued by Shekel sign-in (Google,
  platform SSO links, super-admin impersonation). The login page hides the password form,
  Google and SAML. Personal (user) API access tokens are refused unless the user is in
  `SHEKEL_API_USER_IDS`, and the user JSON leaves the token blank; agent bot tokens work.
  Staff mode keys on the account id, not the OIDC client id, so losing the OIDC settings
  locks everyone out instead of opening the account; production refuses to boot in that
  state.

### What the admin realm gives us

From authentication-api (`IdTokenClaimsBuilder`, `HasOidcSubject::identityClaims`,
`OIDCController::userinfo`):

- **ID token:** `iss` (`.../oauth/admin`), `aud` (client id), `sub` (admin id), `email`,
  `name`, `realm` = `admin`, `nonce`, and with the `tenants` scope
  `tenants: [{"id": "<uuid>", "slug": <string or null>, "country": <lowercase iso or null>}]`
  (always a list; empty when none). Only `id` is used.
- **Userinfo:** `sub`, plus `email` with the `email` scope, `name` with `profile` and
  `tenants` with `tenants`.
- authentication-api PR #682 (the `customer_comms.*` scopes and the `tenants` claim) must be
  deployed before this fork; see the [deploy order](OPERATIONS.md#deploy-order).
- **Token response:** `scope`, the granted scopes. The IdP refuses sign-in without
  `customer_comms.access` only when the client lists it as a required scope, so Chatwoot
  also refuses (`no-account-found`) unless the granted scope includes it.
  `customer_comms.admin` is granted only to admins whose role holds it.

## Register the OAuth client (admin portal)

Ask an authentication-api admin to register, on **staging**:

| Field | Value |
|---|---|
| Realm | `admin` |
| Name | `Chatwoot (local dev)` |
| Grant types | `authorization_code` only (no refresh token needed; Chatwoot keeps its own session) |
| Redirect URIs | `http://localhost:3000/omniauth/shekel/callback` (exact match) |
| Allowed scopes | `customer_comms.access`, `customer_comms.admin` |
| Required scopes | `customer_comms.access` |
| Identity scopes | `openid`, `email`, `profile`, `tenants`: requested by Chatwoot and always granted; not configured as allowed or required |
| Confidential | yes (has a secret; `client_secret_basic`) |
| PKCE | S256 (sent by Chatwoot; fine whether or not the client requires it) |
| first_party | `true`, so staff are not shown a consent screen |

Put the `SHEKEL_OIDC_*` values in `.env.shekel-oidc` (gitignored, mode 0600) rather than
`.env`. `docker-compose.shekel.yaml` loads it into `rails` after `.env`, so it wins, and the
client can be set or rotated without opening `.env`. Then recreate `rails`:
`$DC up -d --no-deps --force-recreate rails`.

On staging, register the client in the admin portal (OAuth settings, staging-admin) or with
`php artisan oauth:register-app --realm=admin ...` (authentication-api S20-4821), with
allowed scopes `customer_comms.access customer_comms.admin` and required scope
`customer_comms.access`. Identity scopes (`openid email profile tenants`) are always granted:
do not add them as allowed or required scopes.

Staging client (2026-11-17): `Chatwoot CRM (staging)`, admin realm, first-party,
`authorization_code` + `refresh_token`, `client_secret_basic`. It was registered with allowed
scopes `consent.read` only, before the `customer_comms.*` scopes existed: update it to the
allowed and required scopes above, or every sign-in is refused (no `customer_comms.access`
in the granted scope).

## Operating notes

- **Keep `ENABLE_ACCOUNT_SIGNUP` off.** Staff are provisioned by Shekel sign-in only; public
  sign-up would let anyone create an account of their own.
- **Tenant ids in the cookie.** Only the tenant ids mapped to a team of the staff account
  travel from the first callback hop to the second in the cookie session (about 40 bytes
  each), so an `all_tenants` admin no longer overflows it. More than about 60 *mapped*
  tenants would still hit `ActionDispatch::Cookies::CookieOverflow`.
- **Session lifespan on first deploy.** `SHEKEL_SESSION_LIFESPAN_HOURS` applies to tokens
  issued after the deploy; existing tokens keep their old (two-month) expiry. If the bound
  must hold from day one, clear `users.tokens` on the first deploy (everyone signs in again).
- **Inboxes.** Staff are added to every inbox that exists when they sign in; an inbox created
  later is joined at their next sign-in.
- **Misconfiguration.** If `SHEKEL_CHATWOOT_ACCOUNT_ID` is unset or names no account, sign-in
  redirects to `/app/login?error=shekel-misconfigured` and logs an error.
- **Password routes.** In staff mode, password sign-in, password reset, the
  profile password change and devise_token_auth's registrations routes (`POST`, `PUT/PATCH`,
  `DELETE /auth`) are all refused.

## Team-scoped visibility

In staff mode (`SHEKEL_CHATWOOT_ACCOUNT_ID` set), an **agent** (any non-administrator) sees only part of the
account (`Shekel::ConversationVisibility`, `Shekel::ContactVisibility`,
`app/services/shekel/`). Administrators see everything.

- **Conversations:** those whose team is one of the agent's teams, plus those assigned to the
  agent. An unteamed conversation is visible to administrators and its assignee only. This
  holds for the lists, counts (meta and unread counts), search, filters, every
  per-conversation endpoint (another team's conversation answers 404), notifications,
  mentions and ActionCable events. When a team or assignee change hides a conversation from an
  agent, their dashboard receives `shekel.conversation.hidden` and drops the row.
- **Contacts:** a contact is visible when at least one of its conversations is. **A contact
  with no conversations is visible to administrators only**, so an agent cannot open one, or
  start a conversation with one; an administrator (or the gateway) starts the first
  conversation. Contact events go to administrators and the agents who can see the contact.
- **Inbound WhatsApp conversations start unteamed**, so agents see them only once the gateway
  or the triage team sets a team (or assigns one).
- **Agent-created conversations:** a conversation an agent starts without a team goes to
  their team when they have exactly one; otherwise, if they still could not see it and it has
  no assignee, it is assigned to them.
- **Integrations** (the Shailoq gateway and any other API client) must use an agent bot token,
  or the token of an administrator service user listed in `SHEKEL_API_USER_IDS`: every other
  user's token is refused in staff mode.
- **Locked to a single conversation:** in such an inbox an agent is handed back only a
  conversation they can see; if none is, a new one is started.
- **Accepted:** notifications created before an agent left a team still appear in their
  notification list with the conversation's metadata; opening one answers 404.

## Staging discovery returns 403 (nginx)

`GET https://auth.shekel.africa/oauth/admin/.well-known/openid-configuration` returns an
nginx 403, while the user-realm document at `/.well-known/openid-configuration` returns 200.
Laravel never sees the request.

Cause (checked read-only on the staging host on 2026-11-17): the vhost includes
`/etc/nginx/snippets/shekel-svc-authentication-api-php.conf`, which has

```nginx
location ^~ /.well-known/ {
    try_files $uri $uri/ /index.php?$query_string;
}

# Deny access to sensitive files
location ~ /\. {
    deny all;
    ...
}
```

The `^~ /.well-known/` exemption only matches the well-known directory at the root. The
admin document is at `/oauth/admin/.well-known/...`, so it falls through to the regex
`location ~ /\.` and is denied. A request to `127.0.0.1` with `Host: auth.shekel.africa` on
the host gives the same 403, so Cloudflare is not involved.

Proposed fix, in the same snippet next to the existing block:

```nginx
# The admin realm is its own issuer (authentication-api OAuthRealmRoutes::issuer),
# so its discovery document sits under /oauth/admin/.well-known/.
location ^~ /oauth/admin/.well-known/ {
    try_files $uri $uri/ /index.php?$query_string;
}
```

then `sudo nginx -t && sudo systemctl reload nginx`. Check whether the production host
uses the same snippet; it would have the same problem. Until then, keep
`SHEKEL_OIDC_DISCOVERY` off and set the endpoints explicitly.

## Tests

```sh
$DC run --rm --no-deps -e RAILS_ENV=test rails bundle exec rails db:schema:load
$DC run --rm --no-deps -e RAILS_ENV=test rails bundle exec rspec \
  spec/controllers/devise/shekel_oidc_callbacks_spec.rb spec/services/shekel \
  spec/controllers/devise_overrides/shekel_password_login_guard_spec.rb \
  spec/controllers/devise/omniauth_callbacks_controller_spec.rb
```

The specs set every `SHEKEL_OIDC_*` variable they depend on, so the real values that
compose loads from `.env` do not leak into them.

Upstream's specs expect upstream behaviour (password sign-in, inbox-wide visibility, user
API tokens), which is what they get while staff mode is off. Staff mode keys on
`SHEKEL_CHATWOOT_ACCOUNT_ID`, which the local `.env` does not set; if yours does, run
upstream specs with `-e SHEKEL_CHATWOOT_ACCOUNT_ID=`. The Shekel specs set staff mode
themselves. `-e SHEKEL_OIDC_CLIENT_ID=` keeps a real client id out of the specs that build
the OmniAuth request.

## Building the images from a worktree

In a git worktree `.git` is a pointer file to a repo outside the Docker build context, so
upstream's `RUN git rev-parse HEAD` failed. The fork's `docker/Dockerfile` falls back to
the `GIT_SHA` build arg (or `unknown`). Pass `--build-arg GIT_SHA=$(git rev-parse HEAD)`
when the image's reported version matters.
