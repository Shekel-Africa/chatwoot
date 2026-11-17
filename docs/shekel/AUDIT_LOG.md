# Audit log (append-only)

SOC2 evidence of who opened, replied to, assigned, resolved or exported which conversation,
and when. Chatwoot's own audit log is enterprise-only (`Enterprise::AuditLog`, built on the
`audited` gem), so the fork keeps its own table, `shekel_audit_events`, and does not use
`audited` or anything under `enterprise/`.

## What is recorded

Each row has `account_id`, `actor_type` / `actor_id` (polymorphic: usually `User`; also
`AgentBot`, `AutomationRule`, `Inbox`, `AssignmentPolicy` or `Contact` when upstream says one
of those made the change; empty for the system, e.g. a snooze expiring), `action`,
`subject_type` / `subject_id`, `metadata` (jsonb), `ip_address` and `created_at`.

| Action | When | Recorded in | Metadata |
| --- | --- | --- | --- |
| `staff.signed_in` | staff OIDC sign-in completes | `ShekelOidcSignIn#sign_in_shekel_staff` | `provider` |
| `staff.signed_out` | a session token is revoked (`DELETE /auth/sign_out`) | `DeviseOverrides::SessionsController#destroy` | — |
| `conversation.viewed` | conversation opened or its messages loaded (by a user or an agent bot token); at most once per actor per conversation per hour (Redis key) | `ConversationsController#show` (via `Shekel::ConversationAuditHooks`), `Conversations::MessagesController#index` | `display_id` |
| `conversation.replied` | outgoing, non-private message whose sender is a `User` | `Shekel::AuditListener#message_created` | `message_id`, `display_id` |
| `conversation.note_added` | private note whose sender is a `User` | `Shekel::AuditListener#message_created` | `message_id`, `display_id` |
| `conversation.assigned` | `assignee_id` changes | `Shekel::AuditListener#assignee_changed` | `from_assignee_id`, `to_assignee_id` |
| `conversation.team_changed` | `team_id` changes | `Shekel::AuditListener#team_changed` | `from_team_id`, `to_team_id` |
| `conversation.resolved` | status becomes resolved | `Shekel::AuditListener#conversation_resolved` | `from_status`, `to_status` |
| `conversation.reopened` | status becomes open (from resolved, pending or snoozed) | `Shekel::AuditListener#conversation_opened` | `from_status`, `to_status` |
| `conversation.transcript_sent` | transcript emailed | `ConversationsController#transcript` (via `Shekel::ConversationAuditHooks`) | `display_id` (never the address) |
| `contacts.exported` | contacts export queued | `ContactsController#export` (via `Shekel::ContactAuditHooks`), `DataExportsController#create` / `#rerun` | `data_export_id`, `data_type` |
| `data_export.downloaded` | the export file's download URL is handed out (the actual retrieval) | `DataExportsController#download` | `data_export_id`, `data_type` |
| `data_import.downloaded` | an import's error log, skip log or rejected-rows file downloaded (they can hold contact details) | `DataImportsController#error_logs` / `#skip_logs` / `#rejected_rows` (via `Shekel::DataImportAuditHooks`) | `data_import_id`, `kind` (`error_logs`, `skip_logs`, `rejected_rows`) |
| `csat.exported` | CSAT responses downloaded as CSV | `CsatSurveyResponsesController#download` | `since`, `until` (epoch seconds), `user_ids`, `inbox_id`, `team_id`, `rating` (filters as sent) |
| `audit.exported` | this log downloaded as CSV | `Shekel::AuditEventsController#index` | `from`, `to` |

Controller-recorded actions only happen when the action succeeded; a refused request records
nothing.

Bot and system replies are not staff replies and are not recorded. Agent-bot and AI
assignee changes are not recorded as `conversation.assigned`.

Metadata holds IDs and statuses only. `Shekel::Audit.record` drops every key outside an
allow-list (`Shekel::Audit::METADATA_KEYS`), so message content, emails, phone numbers and
names cannot reach the log.

### Where the actor comes from

- Controller actions are recorded synchronously, with `Current.user` and `request.remote_ip`.
- Listener actions run later in `EventDispatcherJob` (`Shekel::AuditListener` is registered in
  `AsyncDispatcher`), where `Current` is empty, so `ip_address` is empty and the actor comes
  from the event payload. Messages carry their `sender`. Conversation events carry only
  `performed_by` (`Current.executed_by`, which upstream sets for automations, auto-assignment
  and contact reopens, not for a signed-in user), so `Shekel::AuditContext`, prepended to
  `Dispatcher`, adds `shekel_audit: { actor_type, actor_id, from_status }` to the payload
  inside the request: `Current.executed_by` when set, otherwise `Current.user`. For an API
  access token, `AccessTokenAuthHelper#authenticate_access_token!` sets `Current.user` to the
  token's owner, a `User` or an `AgentBot`, so a bot that resolves, reopens, assigns or moves
  a conversation through the API is recorded as that `AgentBot`.

Recording never fails the user's action: a failed write is logged and sent to the exception
tracker, the insert runs in a savepoint (so it cannot abort a transaction the caller has
open), and a failed view write releases its throttle key. If Redis is unavailable,
`conversation.viewed` is skipped.

### Not audited

- `GET /api/v2/accounts/:id/reports/{agents,inboxes,labels,teams,conversations_summary,conversation_traffic}`
  CSVs: aggregate counts and timings per agent, inbox, label, team or hour, with no message
  content and no contact or per-conversation rows.
- Password sign-ins (super admins); staff sign in through OIDC (`staff.signed_in`).

## Exporting

Administrators of the account only:

```sh
curl -H "api_access_token: $TOKEN" \
  "https://<chatwoot>/api/v1/accounts/<account_id>/shekel/audit_events?from=2026-11-01&to=2026-11-17" \
  -o audit-log.csv
```

`from` and `to` are ISO 8601 dates, inclusive (whole days in the account's app time zone,
`created_at` in the CSV is UTC). The default is the last 30 days; a range may span at most
366 days, counted inclusively. Rows stream oldest first in batches. Columns: `id, created_at, account_id,
actor_type, actor_id, action, subject_type, subject_id, ip_address, metadata` (metadata as
JSON). Each download is itself recorded as `audit.exported` with its range.

## The append-only guarantee and its limits

- `Shekel::AuditEvent#readonly?` is true once a row is saved: `update` / `destroy` raise
  `ActiveRecord::ReadOnlyRecord`.
- A PostgreSQL trigger, `shekel_audit_events_append_only` (BEFORE UPDATE OR DELETE, FOR EACH
  ROW), raises on every update or delete, so `update_all`, `delete_all` and raw SQL fail too.
  It is created by migration `20261118000002_create_shekel_audit_events` with hairtrigger
  (declared on the model as well, so `rake db:generate_trigger_migration` stays a no-op) and
  is dumped into `db/schema.rb`, which is how test and new databases get it.
- The table has no foreign keys, so deleting an account, user or conversation never touches
  the log (a cascading delete would be refused by the trigger anyway). The app has no delete
  path, and retention jobs must not touch this table.
- **Limits.** A row trigger does not fire on `TRUNCATE`, and a role that owns the table can
  drop or disable the trigger. Database-level protection therefore needs, in production, the
  app's database role to lack `TRUNCATE` on `shekel_audit_events` and not to own it (for
  example: table owned by a migration role, and
  `REVOKE TRUNCATE, UPDATE, DELETE ON shekel_audit_events FROM <app_role>`). Backups and
  database access logs remain the evidence against someone with superuser access.
