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
7. Map tenants to teams and create the triage team (below).
8. Hand the WhatsApp inbox to Shailoq: `bundle exec rails shekel:configure_agent_bot` (below).
9. Add a Sidekiq failure alert for `Shekel::RetentionJob` (dead or retried jobs on the `low`
   queue), then watch a few dry runs of the retention job and turn the dry run off.

## Environment variables

Values live in the deployment's secret store, never in git.

| Variable | Default | Meaning |
|---|---|---|
| `DISABLE_ENTERPRISE` | — | Must be `true` (any value disables enterprise, but use `true`). Community build only. |
| `SHEKEL_OIDC_CLIENT_ID`, `SHEKEL_OIDC_CLIENT_SECRET`, `SHEKEL_OIDC_ISSUER`, `SHEKEL_OIDC_REDIRECT_URI`, `SHEKEL_OIDC_AUTHORIZE_URL`, `SHEKEL_OIDC_TOKEN_URL`, `SHEKEL_OIDC_USERINFO_URL`, `SHEKEL_OIDC_JWKS_URL`, `SHEKEL_OIDC_DISCOVERY` | — | Staff sign-in through authentication-api's admin realm. The client id shows the Shekel button. Meanings in [LOCAL_OIDC_LOGIN.md](LOCAL_OIDC_LOGIN.md#environment-variables). |
| `SHEKEL_CHATWOOT_ACCOUNT_ID` | — | The account staff are provisioned into. Required for sign-in, `shekel:*` tasks and the retention audit row. **Setting it turns staff mode on**: team-scoped visibility, Shekel as the only sign-in (password, Google, SAML and non-Shekel SSO tokens refused), personal API tokens refused, 12-hour sessions. |
| `SHEKEL_SESSION_LIFESPAN_HOURS` | `12` | Staff session length in staff mode. Read at boot. |
| `SHEKEL_API_USER_IDS` | — | Comma-separated user ids whose personal API access token still works in staff mode: the Shailoq gateway's service user, the only user who can set or clear the `shekel_*` contact attributes (see [Locked contact attributes](#locked-contact-attributes)). Every other user's token is refused and blanked in the user JSON; agent bot tokens are unaffected. |
| `SHEKEL_STAFF_HOSTS` | — | Comma-separated bare hostnames staff use (the VPN host): only these get the dashboard, the API, sign-in, `/cable`, Active Storage, Sidekiq Web and `/health`. Normalised like `SHEKEL_PUBLIC_HOST` (case, port and trailing dots ignored). **Every other `Host`** (the public host, an IP, `localhost`, an empty or unknown `Host`) gets only `GET`/`POST /webhooks/whatsapp/<number>` and a bare 404 for everything else, so load-balancer and container health checks must send a staff `Host`. |
| `SHEKEL_PUBLIC_HOST` | — | Bare public hostname Meta delivers webhooks to (scheme, path and port are stripped with a warning). It gets only the webhook paths, like any non-staff `Host`. The guard trusts `Host` only, never `X-Forwarded-Host`: the PUBLIC listener must force `Host` to the public hostname, or reject any request whose `Host` is not the public hostname, otherwise a request through public ingress with `Host: <vpn host>` bypasses the guard. Register Meta's callback URL without a trailing slash; the WhatsApp channel phone number must be digits with an optional leading `+`. The guard is off only when both this and `SHEKEL_STAFF_HOSTS` are unset (local dev); with only one set it logs a warning and still enforces (with no staff hosts, every `Host` is restricted). |
| `SHEKEL_SHAILOQ_WEBHOOK_URL` | — | Read by `shekel:configure_agent_bot` only: the gateway URL the Shailoq agent bot posts webhooks to. |
| `SHEKEL_SHAILOQ_INBOX_ID` | — | Read by `shekel:configure_agent_bot` only: id of the WhatsApp inbox (in `SHEKEL_CHATWOOT_ACCOUNT_ID`) handed to Shailoq. |
| `SHEKEL_WHATSAPP_TYPING_INDICATOR_ENABLED` | `true` | While true, turning typing on in a WhatsApp Cloud conversation (an agent or an agent bot, through `toggle_typing_status`) marks the latest incoming message read and shows "typing..." to the contact. Set `false` to stop calling Meta. See [Seen and typing on WhatsApp](#seen-and-typing-on-whatsapp). |
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

No task creates the triage team: it is a manual, one-off step, and nothing in the fork checks
that it exists. `shekel:map_tenant_team` lowercases the team name it creates (`Acme Motors`
becomes `acme motors`), so a mapped team and a hand-made one with the same name are the
same team.

## Shailoq agent bot

```sh
SHEKEL_SHAILOQ_WEBHOOK_URL=https://<gateway host>/<webhook path> \
SHEKEL_SHAILOQ_INBOX_ID=<WhatsApp inbox id> \
bundle exec rails shekel:configure_agent_bot
```

Creates or updates the agent bot named `Shailoq` in the `SHEKEL_CHATWOOT_ACCOUNT_ID` account
with that webhook URL, and attaches it (active) to the inbox. It is idempotent: run it after
every deploy and whenever the URL changes. The bot's access token and webhook secret are
generated by Chatwoot once and kept across runs; the task never prints them, nor the URL's
path or query. An inbox has one bot: another bot on it is replaced and the task says so.
Read the values when you configure the gateway:

- UI: Settings > Bots, open Shailoq (administrators see the access token and the secret).
- Rails console: `AgentBot.find_by(name: 'Shailoq').access_token.token` and `.secret`.

The gateway uses the access token (`api_access_token` header) to post replies as the bot.

**Webhooks are signed.** Every delivery carries `X-Chatwoot-Timestamp` (unix seconds) and
`X-Chatwoot-Signature: sha256=<hex>`, the HMAC-SHA256 of `"<timestamp>.<raw body>"` with the
bot's secret (`Webhooks::Trigger`; `AgentBotListener` passes `agent_bot.secret` to
`AgentBots::WebhookJob`), plus a unique `X-Chatwoot-Delivery` id. The gateway must verify the
signature and reject stale timestamps; that is its authentication. Do not put a secret in
`SHEKEL_SHAILOQ_WEBHOOK_URL`: the `agent_bots` API returns the URL to every agent and administrator, and Chatwoot itself logs only its scheme, host and path (a failed delivery
logs the URL with the query string and fragment removed, and `AgentBots::WebhookJob` does not
log its arguments). If a secret in the URL is ever needed anyway, name the query key `token`
or `key`, which Rails' `filter_parameters` redacts in request logs, and make sure the gateway's
own ingress and access logs do not record query strings: Chatwoot's nginx never sees this
outbound URL, so that setting lives with the gateway's reverse proxy, not in this repo.

Chatwoot refuses webhook URLs that resolve to a private network. If the gateway is reached on
a private address, set `SAFE_FETCH_ALLOW_PRIVATE_NETWORK=true` (it relaxes every outbound
fetch, so prefer a public hostname behind the gateway's own auth) and restart Rails and Sidekiq.

## Seen and typing on WhatsApp

`POST /api/v1/accounts/:account_id/conversations/:id/toggle_typing_status` with `typing_status=on` (not for private notes) now also tells a **WhatsApp Cloud** contact their message was received: a `Shekel::WhatsappSeenSignalJob` (queue `high`, never retried) calls Meta's mark-as-read with `typing_indicator` for the latest incoming message. The contact sees blue ticks and "typing...". Meta dismisses the indicator when we reply or after 25 seconds, whichever comes first, and has no call to clear it early, so `typing_status=off` sends nothing. Calls for the same message are throttled to one per 20 seconds. Nothing is sent when the 24-hour window is closed, the message is older than 29 days, or the inbox is not WhatsApp Cloud (360dialog, web widget and the other channels are untouched). Failures are logged as `[WHATSAPP_SIGNAL] <label> failed http_status=... meta_error_code=...`, never with message text, phone numbers or message ids.

`POST /api/v1/accounts/:account_id/conversations/:id/reactions` with `message_id` (Chatwoot message id of an incoming message) and `emoji` sends one reaction. Agent bot tokens may call it. It answers `202`, or `422 {"error": "<reason>"}` with one of `unsupported_channel`, `message_not_found`, `message_too_old`, `outside_messaging_window`, `invalid_emoji`. The reaction stays in the contact's chat history and needs an open 24-hour window (Meta error `131009` on messages older than 30 days). It reacts at most once per message (a second call is a no-op). Nothing in Chatwoot calls it by itself: the Shailoq gateway does, on by default (owner decision), with the emoji from `SHAILOQ_WHATSAPP_SEEN_REACTION_EMOJI` (default 👀). Turn it off in the gateway with `SHAILOQ_WHATSAPP_SEEN_REACTION_ENABLED=false`; the typing indicator does not depend on it.

Sources: Meta, [Typing indicators](https://developers.facebook.com/documentation/business-messaging/whatsapp/typing-indicators/), [Mark messages as read](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/mark-message-as-read/), [Reaction messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/reaction-messages/), [Send messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages/).

## Cards on WhatsApp (CTA URL messages)

For **WhatsApp Cloud** and **360dialog** inboxes, an outgoing message with `content_type: cards` (Chatwoot's own `content_attributes.items` shape: `title`, `description`, `media_url`, `actions`) is sent to the contact as Meta interactive **CTA URL** messages, one per card (the first 5 only): an image header, a body and one link button. Other channels are unchanged.

- Header: the image from `media_url`, only when it is an `https` URL; otherwise no header. Meta must be able to fetch it from a public server.
- Body: `title` and `description` joined by a newline, cut to 1024 characters with an ellipsis. Button: the first `link` action with text and an `https` `uri`; its text is cut to 20 characters.
- A card with no usable link action is sent as a plain text message (title, description and the first `uri`, if any).
- If Meta rejects a message that has an image header, it is retried once without the header. This logs `[WHATSAPP_CARDS] image header rejected, retrying without it http_status=... meta_error_code=...`, never the image URL, the phone number or the text.
- The Chatwoot message's `source_id` is the id of the first WhatsApp message sent, so delivery status updates still map to it. Like other session messages, cards need an open 24-hour window.

Source: Meta, [Interactive CTA URL messages](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/interactive-cta-url-messages/).

## Locked contact attributes

Contact custom attributes whose key starts with `shekel_` belong to the Shailoq gateway
(dealer link, tenant and so on). The lock is deny by default
(`Shekel::LockedContactAttributes`, a validation on the `Contact` model): a save that creates,
changes or deletes one fails (`422` through the API) unless it is made by

- a **user** listed in `SHEKEL_API_USER_IDS`, signed in with its personal access token (the
  gateway's service user; a bot token never counts, even if the bot's id equals a listed user id), or
- code inside `Shekel::TrustedWriter.with { ... }`.

Everyone else is refused: staff (administrators too), agent bots, the website widget, the
Public API, contact merge and identify flows that would copy a `shekel_*` key onto another
contact, the CSV import, background jobs and the Rails console. A save that sends an unchanged
`shekel_*` value back is accepted, so a dashboard edit that echoes the attributes still works.

Nothing in this app is wrapped in `Shekel::TrustedWriter`: none of the `shekel:*` tasks, services
or jobs writes these keys, and the CSV import and merges are deliberately not trusted. Use it in
the Rails console for a one-off repair, for example
`Shekel::TrustedWriter.with { contact.update!(custom_attributes: contact.custom_attributes.except('shekel_dealer_id')) }`.

## Unlink: keeping the history, clearing the dealer link

Owner decision O5: on unlink the conversation history is kept. The gateway does not delete
the contact; it clears the contact's `shekel_*` attributes with the service user's token
(a user listed in `SHEKEL_API_USER_IDS`; it needs no administrator role):

```
POST /api/v1/accounts/<account_id>/contacts/<contact_id>/destroy_custom_attributes
api_access_token: <service user's access token>
{ "custom_attributes": ["shekel_dealer_id", "shekel_tenant_id"] }
```

Other custom attributes stay. Keep the token in the gateway's secret store; the service user
never signs in through Shekel, so its token is not rotated. The contact and its conversations
stay in Chatwoot; conversations are removed only by [Retention](#retention) after the usual
inactivity period, and the audit log is not touched.

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

Administrators of the account export the log as CSV with their normal signed-in session
(`devise_token_auth` headers `access-token`, `client`, `uid`). An `api_access_token` works only
for a user in `SHEKEL_API_USER_IDS` (personal tokens are refused otherwise in staff mode):

```sh
curl -H "api_access_token: $TOKEN" \
  "https://<chatwoot>/api/v1/accounts/<account_id>/shekel/audit_events?from=2026-11-01&to=2026-11-17" \
  -o audit-log.csv
```

Ranges, columns and the append-only guarantee are in [AUDIT_LOG.md](AUDIT_LOG.md).

Do not issue Platform API apps while staff mode is on: they can write users' `custom_attributes`.
