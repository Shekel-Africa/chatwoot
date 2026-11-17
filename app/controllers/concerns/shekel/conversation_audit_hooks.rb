# Shekel fork: audit-log call sites for Api::V1::Accounts::ConversationsController,
# kept out of the upstream class body (see docs/shekel/AUDIT_LOG.md). Each runs
# after the action and only when it succeeded, so a refused or failed request
# is never recorded.
module Shekel::ConversationAuditHooks
  extend ActiveSupport::Concern

  included do
    # `if:` rather than `only:`, since the actions are defined on the controller, not here.
    after_action :shekel_audit_conversation_view, if: -> { action_name == 'show' }
    after_action :shekel_audit_transcript_sent, if: -> { action_name == 'transcript' }
  end

  private

  def shekel_audit_conversation_view
    shekel_audit_view(@conversation) if response.successful?
  end

  # The recipient address is never recorded.
  def shekel_audit_transcript_sent
    return unless response.successful?

    shekel_audit('conversation.transcript_sent', subject: @conversation, metadata: { display_id: @conversation.display_id })
  end
end
