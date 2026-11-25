# frozen_string_literal: true

# Shekel fork: shared by the Cloud and 360dialog provider specs.
# The including spec provides `service` and `whatsapp_channel`; `url` is the messages endpoint and
# `request_body` wraps the type-specific fields the way that provider addresses a recipient.
RSpec.shared_examples 'whatsapp cta url cards' do |url:, request_body:|
  let(:cards_url) { url }
  let(:cards_request_body) { request_body }
  let(:json_headers) { { 'Content-Type' => 'application/json' } }
  let(:image_url) { 'https://cdn.example.com/cars/1.jpg' }
  let(:view_url) { 'https://shekel.example.com/cars/1' }
  let(:link_action) { { type: 'link', text: 'View car', uri: view_url } }
  let(:card) { { title: 'Toyota Corolla 2018', description: 'Automatic, 45,000 km', media_url: image_url, actions: [link_action] } }

  def build_cards_message(items, content: 'Toyota Corolla 2018')
    create(:message, message_type: :outgoing, content: content, inbox: whatsapp_channel.inbox,
                     content_type: 'cards', content_attributes: { items: items })
  end

  def ok_response(id)
    { status: 200, body: { messages: [{ id: id }] }.to_json, headers: json_headers }
  end

  def stub_send(fields, response)
    stub_request(:post, cards_url).with(body: cards_request_body.call(fields)).to_return(response)
  end

  def cta_fields(body:, display_text: 'View car', link: view_url, header: nil)
    interactive = { type: 'cta_url', body: { text: body },
                    action: { name: 'cta_url', parameters: { display_text: display_text, url: link } } }
    interactive[:header] = header if header
    { type: 'interactive', interactive: interactive }
  end

  def text_fields(body)
    { type: 'text', text: { body: body } }
  end

  let(:image_header) { { type: 'image', image: { link: image_url } } }

  it 'sends a card as a CTA URL message with an image header' do
    stub = stub_send(cta_fields(body: "Toyota Corolla 2018\nAutomatic, 45,000 km", header: image_header), ok_response('wamid.1'))

    expect(service.send_message('+123456789', build_cards_message([card]))).to eq 'wamid.1'
    expect(stub).to have_been_requested.once
  end

  it 'omits the header when the card has no media_url' do
    stub = stub_send(cta_fields(body: "Toyota Corolla 2018\nAutomatic, 45,000 km"), ok_response('wamid.1'))

    expect(service.send_message('+123456789', build_cards_message([card.except(:media_url)]))).to eq 'wamid.1'
    expect(stub).to have_been_requested.once
  end

  it 'omits the header when the media_url is not https' do
    stub = stub_send(cta_fields(body: "Toyota Corolla 2018\nAutomatic, 45,000 km"), ok_response('wamid.1'))

    expect(service.send_message('+123456789', build_cards_message([card.merge(media_url: 'http://cdn.example.com/1.jpg')]))).to eq 'wamid.1'
    expect(stub).to have_been_requested.once
  end

  it 'sends only the title when the card has no description' do
    stub = stub_send(cta_fields(body: 'Toyota Corolla 2018', header: image_header), ok_response('wamid.1'))

    service.send_message('+123456789', build_cards_message([card.except(:description)]))
    expect(stub).to have_been_requested.once
  end

  it 'truncates the body to 1024 and the button text to 20 characters without splitting multibyte characters' do
    long_card = card.merge(title: 'é' * 2000, description: 'x', actions: [link_action.merge(text: '🚗' * 30)])
    stub = stub_request(:post, cards_url).with do |request|
      interactive = JSON.parse(request.body)['interactive']
      interactive['body']['text'].length == 1024 && interactive['body']['text'].end_with?('…') &&
        interactive['body']['text'].valid_encoding? && interactive['action']['parameters']['display_text'].length == 20
    end.to_return(ok_response('wamid.1'))

    service.send_message('+123456789', build_cards_message([long_card]))
    expect(stub).to have_been_requested.once
  end

  it 'uses the first link action that has an https uri and text' do
    actions = [{ type: 'postback', text: 'Ignore', payload: 'x' }, { type: 'link', text: 'Bad', uri: 'http://insecure.example.com' }, link_action]
    stub = stub_send(cta_fields(body: "Toyota Corolla 2018\nAutomatic, 45,000 km", header: image_header), ok_response('wamid.1'))

    service.send_message('+123456789', build_cards_message([card.merge(actions: actions)]))
    expect(stub).to have_been_requested.once
  end

  it 'falls back to a text message when the card has no usable link action' do
    stub = stub_send(text_fields("Toyota Corolla 2018\nAutomatic, 45,000 km"), ok_response('wamid.1'))

    postback = { type: 'postback', text: 'Reserve', payload: 'reserve' }

    expect(service.send_message('+123456789', build_cards_message([card.merge(actions: [postback])]))).to eq 'wamid.1'
    expect(stub).to have_been_requested.once
  end

  it 'includes the uri in the text fallback when the link is not https' do
    insecure = { type: 'link', text: 'View car', uri: 'http://shekel.example.com/cars/1' }
    stub = stub_send(text_fields("Toyota Corolla 2018\nAutomatic, 45,000 km\nhttp://shekel.example.com/cars/1"), ok_response('wamid.1'))

    service.send_message('+123456789', build_cards_message([card.merge(actions: [insecure])]))
    expect(stub).to have_been_requested.once
  end

  it 'sends the message content as text when there are no items' do
    # The regular text path keeps its own endpoint version, so match any version here.
    stub = stub_request(:post, %r{/messages\z}).with do |request|
      parsed = JSON.parse(request.body)
      parsed['type'] == 'text' && parsed.dig('text', 'body') == 'Toyota Corolla 2018'
    end.to_return(ok_response('wamid.1'))

    message = build_cards_message([card])
    message.content_attributes = {}

    expect(service.send_message('+123456789', message)).to eq 'wamid.1'
    expect(stub).to have_been_requested.once
  end

  context 'when Meta rejects the image header' do
    let(:with_header) { cta_fields(body: "Toyota Corolla 2018\nAutomatic, 45,000 km", header: image_header) }
    let(:without_header) { cta_fields(body: "Toyota Corolla 2018\nAutomatic, 45,000 km") }
    let(:error_body) { { error: { code: 131_053, message: 'Media upload error' }, meta: { developer_message: 'Media upload error' } } }
    let(:error_response) { { status: 400, body: error_body.to_json, headers: json_headers } }

    before { allow(Rails.logger).to receive(:warn) }

    it 'retries once without the header, keeps the message and returns the retry id' do
      rejected = stub_send(with_header, error_response)
      retried = stub_send(without_header, ok_response('wamid.retry'))
      message = build_cards_message([card])

      expect(service.send_message('+123456789', message)).to eq 'wamid.retry'
      expect(rejected).to have_been_requested.once
      expect(retried).to have_been_requested.once
      expect(message.reload.status).not_to eq 'failed'
    end

    it 'logs the http status and Meta error code but not the url, number or text' do
      stub_send(with_header, error_response)
      stub_send(without_header, ok_response('wamid.retry'))

      service.send_message('+123456789', build_cards_message([card]))

      expect(Rails.logger).to have_received(:warn).with(a_string_matching(/http_status=400 meta_error_code=131053/)).once
      expect(Rails.logger).not_to have_received(:warn).with(a_string_matching(/cdn\.example\.com|123456789|Corolla/))
    end

    it 'marks the message failed when the retry is rejected too and does not retry again' do
      stub_send(with_header, error_response)
      retried = stub_send(without_header, error_response)
      message = build_cards_message([card])

      expect(service.send_message('+123456789', message)).to be_nil
      expect(retried).to have_been_requested.once
      expect(message.reload.status).to eq 'failed'
    end

    it 'does not retry a card that had no header' do
      rejected = stub_send(without_header, error_response)

      expect(service.send_message('+123456789', build_cards_message([card.except(:media_url)]))).to be_nil
      expect(rejected).to have_been_requested.once
    end
  end

  context 'with several cards' do
    let(:cards) do
      Array.new(7) { |i| card.merge(title: "Car #{i}", description: nil, media_url: nil) }
    end

    it 'sends each card, capped at 5, and returns the id of the first message sent' do
      stubs = cards.each_with_index.map do |item, i|
        stub_send(cta_fields(body: item[:title]), ok_response("wamid.#{i}"))
      end

      expect(service.send_message('+123456789', build_cards_message(cards))).to eq 'wamid.0'
      expect(stubs.first(5)).to all(have_been_requested.once)
      stubs.last(2).each { |stub| expect(stub).not_to have_been_requested }
    end
  end
end
