# Shekel fork: records `data_import.downloaded` for the import diagnostics of
# Api::V1::Accounts::DataImportsController (error log, skip log, rejected rows),
# which can hold contact details. Kept out of the upstream class body; runs
# after the action, so after authorisation, and only for a successful response.
module Shekel::DataImportAuditHooks
  extend ActiveSupport::Concern

  DOWNLOADS = %w[error_logs skip_logs rejected_rows].freeze

  included do
    # `if:` rather than `only:`, since the actions are defined on the controller, not here.
    after_action :shekel_audit_data_import_download, if: -> { DOWNLOADS.include?(action_name) }
  end

  private

  def shekel_audit_data_import_download
    return unless response.successful? && @data_import

    shekel_audit('data_import.downloaded', subject: @data_import, metadata: { data_import_id: @data_import.id, kind: action_name })
  end
end
