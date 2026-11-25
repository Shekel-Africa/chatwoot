# Shekel fork: sends a Chatwoot `cards` message to WhatsApp as Meta "CTA URL" interactive messages, one per card:
# an optional image header, a short body and ONE link button. Shared by the Cloud and 360dialog providers, which
# only supply #post_message_payload(phone_number, fields) (recipient and endpoint differ between them).
# https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/interactive-cta-url-messages/
module Whatsapp::Providers::CtaUrlCards
  MAX_CARDS = 5
  BODY_LIMIT = 1024 # Meta limit for the interactive body text
  BUTTON_LIMIT = 20 # Meta limit for the button display text
  TEXT_LIMIT = 4096 # Meta limit for a plain text body
  OMISSION = '…'.freeze

  def cards_message?(message)
    message.content_type == 'cards' && card_items(message).present?
  end

  # Returns the id of the first WhatsApp message that was accepted (it becomes the Chatwoot message's source_id,
  # so delivery status updates still map), or nil when none was.
  def send_cards_message(phone_number, message)
    card_items(message).first(MAX_CARDS).filter_map { |item| send_card(phone_number, message, item) }.first
  end

  private

  def card_items(message)
    Array.wrap(message.content_attributes['items']).select { |item| item.is_a?(Hash) }.map(&:with_indifferent_access)
  end

  def send_card(phone_number, message, item)
    link = card_link_action(item)
    return process_response(post_message_payload(phone_number, card_text_fields(item)), message) if link.blank?

    header = card_image_header(item)
    response = post_message_payload(phone_number, card_cta_fields(message, item, link, header))
    if header && !card_accepted?(response)
      log_card_header_rejected(response)
      response = post_message_payload(phone_number, card_cta_fields(message, item, link, nil))
    end
    process_response(response, message)
  end

  def card_cta_fields(message, item, link, header)
    interactive = {
      type: 'cta_url',
      body: { text: card_body(message, item, link) },
      action: { name: 'cta_url', parameters: { display_text: link[:text], url: link[:uri] } }
    }
    interactive[:header] = header if header
    { type: 'interactive', interactive: interactive }
  end

  def card_text_fields(item)
    uri = card_actions(item).filter_map { |action| action[:uri].to_s.strip.presence }.first
    text = [item[:title], item[:description], uri].map { |part| part.to_s.strip }.compact_blank.join("\n")
    { type: 'text', text: { body: text.truncate(TEXT_LIMIT, omission: OMISSION) } }
  end

  def card_body(message, item, link)
    text = [item[:title], item[:description]].map { |part| part.to_s.strip }.compact_blank.join("\n")
    text = message.content.to_s.strip if text.blank?
    text = link[:text] if text.blank?
    text.truncate(BODY_LIMIT, omission: OMISSION)
  end

  # The first link action that has button text and an https uri; Meta only accepts one button per message.
  def card_link_action(item)
    card_actions(item).each do |action|
      next unless action[:type] == 'link' && action[:text].to_s.strip.present? && https_url?(action[:uri])

      return { text: action[:text].to_s.strip.truncate(BUTTON_LIMIT, omission: OMISSION), uri: action[:uri].to_s.strip }
    end
    nil
  end

  def card_actions(item)
    Array.wrap(item[:actions]).select { |action| action.is_a?(Hash) }.map(&:with_indifferent_access)
  end

  def card_image_header(item)
    return unless https_url?(item[:media_url])

    { type: 'image', image: { link: item[:media_url].to_s.strip } }
  end

  def https_url?(value)
    uri = URI.parse(value.to_s.strip)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def card_accepted?(response)
    parsed = response.parsed_response
    response.success? && parsed.is_a?(Hash) && parsed['error'].blank?
  end

  # Logs only the HTTP status and Meta's error code: never the image url, the recipient or the message text.
  def log_card_header_rejected(response)
    Rails.logger.warn "[WHATSAPP_CARDS] image header rejected, retrying without it http_status=#{response.code} " \
                      "meta_error_code=#{card_error_code(response)}"
  end

  # Cloud API: { error: { code } }; 360dialog: { errors: [{ code }] }.
  def card_error_code(response)
    parsed = response.parsed_response
    return unless parsed.is_a?(Hash)

    parsed.dig('error', 'code') || Array.wrap(parsed['errors']).first.try(:[], 'code')
  rescue TypeError
    nil
  end
end
