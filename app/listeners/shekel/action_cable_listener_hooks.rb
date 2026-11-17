# Shekel fork: ActionCableListener changes for Shekel::ConversationVisibility,
# prepended so the upstream listener stays as it is.
#
# - Contact events, which upstream sends to the whole account stream, go only to
#   administrators and the agents who can see the contact.
# - After a team or assignee change, agents who can no longer see the
#   conversation get Shekel::ConversationVisibility::HIDDEN_EVENT, which makes
#   their dashboard drop the row. (Conversation and message events themselves are
#   narrowed in the listener's `conversation_members`.)
module Shekel::ActionCableListenerHooks
  CONTACT_EVENTS = [
    Events::Types::CONTACT_CREATED, Events::Types::CONTACT_UPDATED, Events::Types::CONTACT_MERGED, Events::Types::CONTACT_DELETED
  ].freeze

  def assignee_changed(event)
    super
    broadcast_conversation_hidden(event)
  end

  def team_changed(event)
    super
    broadcast_conversation_hidden(event)
  end

  private

  def broadcast(account, tokens, event_name, data, widget: {})
    tokens = Shekel::ContactVisibility.event_tokens(account: account, contact_id: data[:id]) || tokens if CONTACT_EVENTS.include?(event_name)
    super
  end

  def broadcast_conversation_hidden(event)
    conversation, account = extract_conversation_and_account(event)
    users = Shekel::ConversationVisibility.lost_audience(conversation: conversation, changed_attributes: event.data[:changed_attributes])
    tokens = users.pluck(:pubsub_token)
    return if tokens.empty?

    broadcast(account, tokens, Shekel::ConversationVisibility::HIDDEN_EVENT, { id: conversation.display_id })
  end
end
