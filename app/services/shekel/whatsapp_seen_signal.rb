# Shekel fork: let a WhatsApp contact see that their message was received before the reply is ready.
#
# - typing_on: when an agent or an agent bot turns typing on in a WhatsApp Cloud conversation, mark the latest incoming
#   message read (blue ticks) and show "typing..." (Meta's typing indicator). Meta dismisses it when we reply or after
#   25 seconds. There is no call to clear it early, so typing off sends nothing.
# - react: send an emoji reaction to one incoming message (opt-in; the Shailoq gateway turns it on with
#   SHAILOQ_WHATSAPP_SEEN_REACTION_ENABLED).
#
# Only Channel::Whatsapp with provider whatsapp_cloud is affected; every other channel is a no-op. All of it is best
# effort: it never raises into the caller, and it never logs message text, phone numbers or message ids.
#
# SHEKEL_WHATSAPP_TYPING_INDICATOR_ENABLED=false switches the typing indicator off (default on).
#
# Called from Conversations::TypingStatusManager, Api::V1::Accounts::Conversations::ReactionsController and
# Shekel::WhatsappSeenSignalJob.
module Shekel::WhatsappSeenSignal
  # Meta shows the indicator for 25 seconds; resend a little before that so a long typing session keeps it alive
  # without calling Meta on every keystroke.
  TYPING_THROTTLE_SECONDS = 20
  # Meta rejects mark-as-read and reactions for messages older than 30 days; stay clear of the edge.
  MAX_MESSAGE_AGE = 29.days
  MAX_EMOJI_LENGTH = 16

  module_function

  def cloud_channel?(conversation)
    channel = conversation.inbox.channel
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end

  def typing_enabled?
    ENV.fetch('SHEKEL_WHATSAPP_TYPING_INDICATOR_ENABLED', 'true').to_s.casecmp?('true')
  end

  # Called inline from the typing endpoint: enqueue only, so the request never waits on Meta.
  def enqueue_typing(conversation)
    return unless typing_enabled? && cloud_channel?(conversation)

    Shekel::WhatsappSeenSignalJob.perform_later(conversation.id)
  rescue StandardError => e
    Rails.logger.warn "[WHATSAPP_SIGNAL] typing enqueue failed error=#{e.class}"
  end

  def typing_on(conversation)
    return false unless typing_enabled? && cloud_channel?(conversation) && conversation.can_reply?

    message = latest_incoming_message(conversation)
    return false if message.blank? || !throttle_acquired?(conversation, message)

    conversation.inbox.channel.provider_service.send_typing_indicator(message.source_id)
  end

  # Why a reaction cannot be sent, as a stable label (nil when it can): the controller answers 422 with it.
  def reaction_problem(conversation, message, emoji)
    return :unsupported_channel unless cloud_channel?(conversation)

    message_problem(message) || (:outside_messaging_window unless conversation.can_reply?) || (:invalid_emoji unless valid_emoji?(emoji))
  end

  def message_problem(message)
    return :message_not_found unless message&.incoming? && message.source_id.present?

    :message_too_old if message.created_at < MAX_MESSAGE_AGE.ago
  end

  def react(conversation, message, emoji)
    return false if reaction_problem(conversation, message, emoji)

    conversation.inbox.channel.provider_service.send_reaction(conversation.contact_inbox.source_id, message.source_id, emoji)
  end

  def valid_emoji?(emoji)
    emoji.is_a?(String) && emoji.strip.present? && emoji.length <= MAX_EMOJI_LENGTH
  end

  def latest_incoming_message(conversation)
    message = conversation.messages.incoming.where.not(source_id: [nil, '']).order(:created_at, :id).last
    message if message && message.created_at >= MAX_MESSAGE_AGE.ago
  end

  def throttle_acquired?(conversation, message)
    key = "SHEKEL::WHATSAPP_TYPING::#{conversation.id}::#{message.id}"
    Redis::Alfred.set(key, 1, nx: true, ex: TYPING_THROTTLE_SECONDS).present?
  end
end
