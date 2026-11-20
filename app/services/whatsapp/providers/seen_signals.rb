# Shekel fork: the Meta Cloud API calls behind Shekel::WhatsappSeenSignal, kept out of the provider class.
# Needs phone_id_path, api_headers and recipient_params from the including provider.
module Whatsapp::Providers::SeenSignals
  SIGNAL_TIMEOUT_SECONDS = 5

  # Shekel fork: tells the contact their message was received. Marks the incoming message read (blue ticks) and
  # shows "typing..." until we reply or 25 seconds pass, whichever comes first; Meta has no call to clear it early.
  # https://developers.facebook.com/documentation/business-messaging/whatsapp/typing-indicators/
  # Best effort: returns true or false, never raises, logs only a label, the HTTP status and Meta's error code.
  def send_typing_indicator(message_id)
    post_best_effort(
      'typing_indicator',
      { messaging_product: 'whatsapp', status: 'read', message_id: message_id, typing_indicator: { type: 'text' } }
    ) { |parsed| parsed['success'] == true }
  end

  # Shekel fork: reacts to an incoming message with an emoji. Stays in the contact's chat history. Needs an open
  # 24-hour window; Meta rejects messages older than 30 days (error 131009).
  # https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/reaction-messages/
  def send_reaction(phone_number, message_id, emoji)
    post_best_effort(
      'reaction',
      { messaging_product: 'whatsapp', recipient_type: 'individual', **recipient_params(phone_number),
        type: 'reaction', reaction: { message_id: message_id, emoji: emoji } }
    ) { |parsed| parsed['messages'].present? }
  end

  private

  # The typing indicator needs a recent Graph API version; v24.0 is the one the attachment send already uses.
  def post_best_effort(label, request_body)
    response = HTTParty.post("#{phone_id_path('v24.0')}/messages", headers: api_headers, timeout: SIGNAL_TIMEOUT_SECONDS,
                                                                   body: request_body.to_json)
    parsed = response.parsed_response
    return true if response.success? && parsed.is_a?(Hash) && yield(parsed)

    code = parsed.is_a?(Hash) ? parsed.dig('error', 'code') : nil
    Rails.logger.warn "[WHATSAPP_SIGNAL] #{label} failed http_status=#{response.code} meta_error_code=#{code}"
    false
  rescue StandardError => e
    Rails.logger.warn "[WHATSAPP_SIGNAL] #{label} failed error=#{e.class}"
    false
  end
end
