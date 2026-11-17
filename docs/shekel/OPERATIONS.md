# Operating the Shekel fork

Day-to-day operation of the Shekel fork of Chatwoot. Local setup and the sign-in design are
in [LOCAL_OIDC_LOGIN.md](LOCAL_OIDC_LOGIN.md); the audit log is in [AUDIT_LOG.md](AUDIT_LOG.md).

## Deploy order

1. Deploy authentication-api #682 (the `customer_comms.*` scopes and the `tenants` claim),
   then run its post-deploy steps: `php artisan permissions:update-tenants` and clear the
   `policies` cache, or the new permissions are not granted.
2. In shekel-admin-fe, grant `customer_comms.access` (and `customer_comms.admin` to CRM
   administrators) to the staff roles that use the CRM. Without it only `admin.admin`
   holders can sign in, and they are made Chatwoot administrators.
3. Reconfigure the OAuth client (allowed scopes `customer_comms.access
   customer_comms.admin`, required scope `customer_comms.access`); see
   [Register the OAuth client](LOCAL_OIDC_LOGIN.md#register-the-oauth-client-admin-portal).
   Until then every Shekel sign-in is refused.
4. Deploy this fork, run migrations, then `bundle exec rails shekel:configure`. Set
   `SHEKEL_STAFF_HOSTS`, `SHEKEL_PUBLIC_HOST` and `SHEKEL_API_USER_IDS` (below) with the
   rest of the environment. Production refuses to boot with `SHEKEL_CHATWOOT_ACCOUNT_ID`
   set and `SHEKEL_OIDC_CLIENT_ID` blank.
5. **Setting `SHEKEL_CHATWOOT_ACCOUNT_ID` turns staff mode on at once**: password sign-in,
   Google, SAML and personal API tokens stop working on that restart. Before relying on it,
   confirm one Shekel sign-in works end to end. The break-glass is a super admin
   (`/super_admin`, its own Devise sign-in, not affected by staff mode); keep one.
6. On the first deploy, clear `users.tokens` (`User.update_all(tokens: {})`) so sessions
   issued before staff mode (two-month expiry) end and everyone signs in through Shekel.
7. Map tenants to teams (below).
8. Add a Sidekiq failure alert for `Shekel::RetentionJob` (dead or retried jobs on the `low`
   queue), then watch a few dry runs of the retention job and turn the dry run off.

## Environment variables

Values live in the deployment's secret store, never in git.

| Variable | Default | Meaning |
|---|---|---|
| `DISABLE_ENTERPRISE` | — | Must be `true` (any value disables enterprise, but use `true`). Community build only. |
| `SHEKEL_OIDC_CLIENT_ID`, `SHEKEL_OIDC_CLIENT_SECRET`, `SHEKEL_OIDC_ISSUER`, `SHEKEL_OIDC_REDIRECT_URI`, `SHEKEL_OIDC_AUTHORIZE_URL`, `SHEKEL_OIDC_TOKEN_URL`, `SHEKEL_OIDC_USERINFO_URL`, `SHEKEL_OIDC_JWKS_URL`, `SHEKEL_OIDC_DISCOVERY` | — | Staff sign-in through authentication-api's admin realm. The client id shows the Shekel button. Meanings in [LOCAL_OIDC_LOGIN.md](LOCAL_OIDC_LOGIN.md#environment-variables). |
| `SHEKEL_CHATWOOT_ACCOUNT_ID` | — | The account staff are provisioned into. Required for sign-in, `shekel:*` tasks and the retention audit row. **Setting it turns staff mode on**: team-scoped visibility, Shekel as the only sign-in (password, Google, SAML and non-Shekel SSO tokens refused), personal API tokens refused, 12-hour sessions. |
| `SHEKEL_SESSION_LIFESPAN_HOURS` | `12` | Staff session length in staff mode. Read at boot. |
| `SHEKEL_API_USER_IDS` | — | Comma-separated user ids whose personal API access token still works in staff mode: the Shailoq gateway's administrator service user (contact deletion on unlink). Every other user's token is refused and blanked in the user JSON; agent bot tokens are unaffected. |
| `SHEKEL_STAFF_HOSTS` | — | Comma-separated bare hostnames staff use (the VPN host): only these get the dashboard, the API, sign-in, `/cable`, Active Storage, Sidekiq Web and `/health`. Normalised like `SHEKEL_PUBLIC_HOST` (case, port and trailing dots ignored). **Every other `Host`** (the public host, an IP, `localhost`, an empty or unknown `Host`) gets only `GET`/`POST /webhooks/whatsapp/<number>` and a bare 404 for everything else, so load-balancer and container health checks must send a staff `Host`. |
| `SHEKEL_PUBLIC_HOST` | — | Bare public hostname Meta delivers webhooks to (scheme, path and port are stripped with a warning). It gets only the webhook paths, like any non-staff `Host`. The guard trusts `Host` only, never `X-Forwarded-Host`: the PUBLIC listener must force `Host` to the public hostname, or reject any request whose `Host` is not the public hostname, otherwise a request through public ingress with `Host: <vpn host>` bypasses the guard. Register Meta's callback URL without a trailing slash; the WhatsApp channel phone number must be digits with an optional leading `+`. The guard is off only when both this and `SHEKEL_STAFF_HOSTS` are unset (local dev); with only one set it logs a warning and still enforces (with no staff hosts, every `Host` is restricted). |
| `SHEKEL_RETENTION_BOT_ONLY_DAYS` | `30` | Days of inactivity before a bot-only conversation is deleted. |
| `SHEKEL_RETENTION_WITH_PERSON_MONTHS` | `12` | Months of inactivity before a conversation a person took part in is deleted. |
| `SHEKEL_RETENTION_DRY_RUN` | `true` | While true (or unset), the retention job only counts, logs and audits. Set `false` to delete. |

## Account configuration

```sh
bundle exec rails shekel:configure
```

For the `SHEKEL_CHATWOOT_ACCOUNT_ID` account: turns `keep_pending_on_bot_failure` off (a
conversation goes to the staff queue when Shailoq fails instead of staying pending), sets
the installation config `ENABLE_ACCOUNT_SIGNUP` to `false`, and prints the tenant-team
mapping. It is idempotent: run it after every deploy.

## Tenants, teams and triage

One team per country (tenant). Staff join the team mapped from each tenant they hold at
their next Shekel sign-in.

```sh
bundle exec rails "shekel:map_tenant_team[<tenant uuid>,Acme Motors]"  # creates the team if missing
bundle exec rails shekel:list_tenant_teams
```

**Triage team.** Inbound WhatsApp conversations start unteamed. The gateway sets the
country team from the linked dealer's tenant; public-mode (unlinked) conversations go to a
triage team. Create it once as an ordinary team (Settings > Teams, e.g. `triage`), do not
map it to a tenant, and add its members by hand: staff sync only adds and removes mapped
teams, so manual membership of the triage team survives sign-ins. Agents see only their
teams' conversations; administrators see all.

## Unlink: deleting a dealer's data

On unlink or account closure the gateway deletes the contact through Chatwoot's API:

```
DELETE /api/v1/accounts/<account_id>/contacts/<contact_id>
api_access_token: <administrator's access token>
```

This deletes the contact and, in the background, its conversations and messages. It needs
an **administrator user's** access token: `ContactPolicy#destroy?` allows administrators
only, so an agent bot token (and an agent's) is refused. Use a dedicated administrator
service user, list its id in `SHEKEL_API_USER_IDS` (other users' tokens are refused in staff
mode) and keep its token in the gateway's secret store. It never signs in through Shekel, so
its token is not rotated. The audit log is not touched.

## Retention

`Shekel::RetentionJob` runs daily at 02:30 UTC (`config/schedule.yml`, queue `low`) and calls
`Shekel::Retention` for every account. Age is measured from `conversations.last_activity_at`.

- **With a person**: an outgoing `User` message, a `User`-authored private note, or a
  WhatsApp-app echo (a staff reply sent from the WhatsApp Business app). Deleted after
  `SHEKEL_RETENTION_WITH_PERSON_MONTHS` (12) months. Website campaign conversations count
  as with a person when the campaign has a `User` sender (its first message is an outgoing
  `User` message), so they are kept 12 months.
- **Bot-only**: everything else (contact, Shailoq, activity messages, and private notes from
  Shailoq, automations, macros or the system). Deleted after
  `SHEKEL_RETENTION_BOT_ONLY_DAYS` (30) days.
- Conversations snoozed until a future time are skipped.

Each conversation is deleted by its own upstream `DeleteObjectJob` (queue `low`), enqueued
in batches of 500. Only conversations (and their messages, attachments and so on) are
deleted: contacts stay, and the audit log is never deleted by the app. Re-running is safe;
a conversation still queued from the day before is enqueued again and the extra job is
discarded once the first has deleted it.

Each run writes one `retention.purged` audit row (actor empty, filed under
`SHEKEL_CHATWOOT_ACCOUNT_ID`, or no account with a logged warning if it is unset) with
`bot_only_enqueued` and `with_person_enqueued` for all accounts, both cutoffs and
`dry_run`, and logs the same line (`Shekel retention ...`).

**Dry run.** `SHEKEL_RETENTION_DRY_RUN` defaults to `true`: the job counts what it would
delete, logs and audits it, and enqueues nothing. Check the counts for a few days, then set
it to `false` and restart Sidekiq. Deletion is irreversible.

## Audit export

Administrators of the account export the log as CSV, with the token of a user in
`SHEKEL_API_USER_IDS` (personal tokens are refused otherwise in staff mode):

```sh
curl -H "api_access_token: $TOKEN" \
  "https://<chatwoot>/api/v1/accounts/<account_id>/shekel/audit_events?from=2026-11-01&to=2026-11-17" \
  -o audit-log.csv
```

Ranges, columns and the append-only guarantee are in [AUDIT_LOG.md](AUDIT_LOG.md).
