# Shekel fork: sends Meta's "seen + typing" signal, or one reaction, off the request thread. High priority because
# a signal that arrives after the reply is useless. Never retried for the same reason.
class Shekel::WhatsappSeenSignalJob < ApplicationJob
  queue_as :high

  discard_on StandardError

  def perform(conversation_id, message_id = nil, emoji = nil)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.blank?

    if message_id.present?
      Shekel::WhatsappSeenSignal.react(conversation, conversation.messages.find_by(id: message_id), emoji)
    else
      Shekel::WhatsappSeenSignal.typing_on(conversation)
    end
  end
end
