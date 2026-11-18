# Shekel fork: records `contacts.exported` for
# Api::V1::Accounts::ContactsController#export, kept out of the upstream class
# body. The action does not keep the export it queues, so the hook notes the
# account's newest export id before the action and records the exports this
# user created during it (normally exactly one), only when the action succeeded.
module Shekel::ContactAuditHooks
  extend ActiveSupport::Concern

  included do
    # `if:` rather than `only:`, since the action is defined on the controller, not here.
    before_action :shekel_note_last_export_id, if: -> { action_name == 'export' }
    after_action :shekel_audit_contacts_export, if: -> { action_name == 'export' }
  end

  private

  def shekel_note_last_export_id
    @shekel_last_export_id = Current.account.data_exports.maximum(:id) || 0
  end

  def shekel_audit_contacts_export
    return unless response.successful? && Current.user

    Current.account.data_exports.where(id: (@shekel_last_export_id + 1).., initiated_by_id: Current.user.id)
           .find_each { |data_export| shekel_audit_export(data_export) }
  end
end
