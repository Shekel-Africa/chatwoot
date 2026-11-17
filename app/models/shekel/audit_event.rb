# Shekel fork: one row of the append-only audit log. Write through
# Shekel::Audit.record; see docs/shekel/AUDIT_LOG.md.
#
# Rows are read-only once created, and the database refuses UPDATE and DELETE
# on the table (the trigger below, created by
# 20261118000002_create_shekel_audit_events), so `update_all` / `delete_all`
# fail too.
class Shekel::AuditEvent < ApplicationRecord
  self.table_name = 'shekel_audit_events'

  ACTIONS = %w[
    staff.signed_in staff.signed_out
    conversation.viewed conversation.replied conversation.note_added
    conversation.assigned conversation.team_changed
    conversation.resolved conversation.reopened
    conversation.transcript_sent
    contacts.exported data_export.downloaded csat.exported audit.exported
  ].freeze

  validates :action, inclusion: { in: ACTIONS }

  trigger.name('shekel_audit_events_append_only').before(:update, :delete).for_each(:row) do
    "RAISE EXCEPTION 'shekel_audit_events is append-only';"
  end

  def readonly?
    persisted? || super
  end
end
