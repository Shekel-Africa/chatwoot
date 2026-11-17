# Shekel fork: append-only audit log (SOC2 evidence of who opened, replied to,
# assigned, resolved or exported which conversation, and when).
#
# No foreign keys: the log must outlive the accounts, users and conversations
# it mentions, and a cascading delete would be refused by the trigger anyway.
# The trigger is declared on Shekel::AuditEvent as well, as hairtrigger
# expects, so `rake db:generate_trigger_migration` stays a no-op.
class CreateShekelAuditEvents < ActiveRecord::Migration[8.0]
  def up # rubocop:disable Metrics/MethodLength
    create_table :shekel_audit_events do |t|
      t.bigint :account_id
      t.string :actor_type
      t.bigint :actor_id
      t.string :action, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.jsonb :metadata, null: false, default: {}
      t.inet :ip_address
      t.datetime :created_at, null: false
    end
    add_index :shekel_audit_events, [:account_id, :created_at]
    add_index :shekel_audit_events, [:subject_type, :subject_id]

    create_trigger('shekel_audit_events_append_only', generated: true, compatibility: 1)
      .on('shekel_audit_events')
      .name('shekel_audit_events_append_only')
      .before(:update, :delete)
      .for_each(:row) do
      "RAISE EXCEPTION 'shekel_audit_events is append-only';"
    end
  end

  def down
    drop_trigger('shekel_audit_events_append_only', 'shekel_audit_events', generated: true)
    drop_table :shekel_audit_events
  end
end
