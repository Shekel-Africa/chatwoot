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
| `SHEKEL_CHATWOOT_ACCOUNT_ID` | Required for sign-in. The account staff are provisioned into. |
| `SHEKEL_SESSION_LIFESPAN_HOURS` | Optional, default `12`. How long a staff session lasts when Shekel sign-in is configured (devise_token_auth `token_lifespan`). Read at boot. |
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
    result on, together with the tenant ids from the `tenants` claim and whether the
    token response's `scope` (`credentials.scope`) grants `customer_comms.admin`;
  - `Shekel::StaffSync` (`app/services/shekel/staff_sync.rb`) then provisions and syncs
    the staff member: creates the user if the email is unknown (random password,
    confirmed), sets the role (administrator with `customer_comms.admin`, else agent),
    joins the teams mapped from held tenants and leaves mapped teams for tenants no
    longer held (unmapped teams are untouched), and adds them to every inbox. If the
    `tenants` claim is absent (an older IdP), team membership is left as it is and a
    warning is logged; an explicit empty list removes them from all mapped teams;
  - the user signs in through upstream's SSO-token path (the same as Google sign-in).
- With `SHEKEL_OIDC_CLIENT_ID` set, password sign-in, password reset and the profile
  password change are refused ("Sign in with Shekel instead.",
  `ShekelPasswordLoginGuard`), and the login page hides the password form. The SSO-token
  sign-in and API access tokens still work.

### What the admin realm gives us

From authentication-api (`IdTokenClaimsBuilder`, `HasOidcSubject::identityClaims`,
`OIDCController::userinfo`):

- **ID token:** `iss` (`.../oauth/admin`), `aud` (client id), `sub` (admin id), `email`,
  `name`, `realm` = `admin`, `nonce`, and with the `tenants` scope
  `tenants: [{"id": "<uuid>", "slug": <string or null>, "country": <lowercase iso or null>}]`
  (always a list; empty when none). Only `id` is used.
- **Userinfo:** `sub`, plus `email` with the `email` scope, `name` with `profile` and
  `tenants` with `tenants`.
- **Token response:** `scope`, the granted scopes. Sign-in is refused by the IdP without
  `customer_comms.access`; `customer_comms.admin` is granted to CRM admins only.

## Register the OAuth client (admin portal)

Ask an authentication-api admin to register, on **staging**:

| Field | Value |
|---|---|
| Realm | `admin` |
| Name | `Chatwoot (local dev)` |
| Grant types | `authorization_code` only (no refresh token needed; Chatwoot keeps its own session) |
| Redirect URIs | `http://localhost:3000/omniauth/shekel/callback` (exact match) |
| Scopes | `openid`, `email`, `profile`, `tenants`, `customer_comms.access`, `customer_comms.admin` |
| Confidential | yes (has a secret; `client_secret_basic`) |
| PKCE | S256 (sent by Chatwoot; fine whether or not the client requires it) |
| first_party | `true`, so staff are not shown a consent screen |

Put the `SHEKEL_OIDC_*` values in `.env.shekel-oidc` (gitignored, mode 0600) rather than
`.env`. `docker-compose.shekel.yaml` loads it into `rails` after `.env`, so it wins, and the
client can be set or rotated without opening `.env`. Then recreate `rails`:
`$DC up -d --no-deps --force-recreate rails`.

On staging, register the client in the admin portal (OAuth settings, staging-admin) or with
`php artisan oauth:register-app --realm=admin ... --scopes= --secret-file=<new path>`
(authentication-api S20-4821). The portal requires at least one allowed scope; pick
`consent.read`, which Chatwoot never requests. `openid email profile` are identity scopes,
always granted: do not add them as allowed or required scopes.

Staging client (2026-11-17): `Chatwoot CRM (staging)`, admin realm, first-party,
`authorization_code` + `refresh_token`, `client_secret_basic`, allowed scopes `consent.read`.

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

Upstream's sign-in and password specs (`spec/controllers/devise`,
`spec/controllers/devise_overrides`, `spec/controllers/api/v1/profiles_controller_spec.rb`)
expect password sign-in to work, so run them with `-e SHEKEL_OIDC_CLIENT_ID=` when
`.env.shekel-oidc` sets a client id; otherwise the password guard refuses them.

## Building the images from a worktree

In a git worktree `.git` is a pointer file to a repo outside the Docker build context, so
upstream's `RUN git rev-parse HEAD` failed. The fork's `docker/Dockerfile` falls back to
the `GIT_SHA` build arg (or `unknown`). Pass `--build-arg GIT_SHA=$(git rev-parse HEAD)`
when the image's reported version matters.
