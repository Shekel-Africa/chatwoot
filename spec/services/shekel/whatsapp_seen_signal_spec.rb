require 'rails_helper'

RSpec.describe Shekel::WhatsappSeenSignal do
  let(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:conversation) { create(:conversation, inbox: inbox, account: inbox.account) }
  let(:messages_url) { 'https://graph.facebook.com/v24.0/123456789/messages' }
  let(:json_headers) { { 'Content-Type' => 'application/json' } }
  let!(:incoming) do
    create(:message, conversation: conversation, account: inbox.account, inbox: inbox, message_type: :incoming, source_id: 'wamid.incoming')
  end

  before do
    stub_request(:get, %r{graph.facebook.com/v14.0/.*message_templates})
    stub_request(:post, messages_url).to_return(status: 200, body: { success: true }.to_json, headers: json_headers)
    Redis::Alfred.delete("SHEKEL::WHATSAPP_TYPING::#{conversation.id}::#{incoming.id}")
  end

  describe '.typing_on' do
    it 'marks the latest incoming message read with a typing indicator' do
      latest = create(:message, conversation: conversation, account: inbox.account, inbox: inbox, message_type: :incoming, source_id: 'wamid.latest')

      expect(described_class.typing_on(conversation)).to be(true)

      expect(a_request(:post, messages_url).with(
               body: { messaging_product: 'whatsapp', status: 'read', message_id: 'wamid.latest', typing_indicator: { type: 'text' } }.to_json
             )).to have_been_made.once
      Redis::Alfred.delete("SHEKEL::WHATSAPP_TYPING::#{conversation.id}::#{latest.id}")
    end

    it 'does not call Meta again within the throttle window' do
      described_class.typing_on(conversation)
      expect(described_class.typing_on(conversation)).to be(false)

      expect(a_request(:post, messages_url)).to have_been_made.once
    end

    it 'does nothing when the 24 hour window is closed' do
      incoming.update!(created_at: 25.hours.ago)

      expect(described_class.typing_on(conversation)).to be(false)
      expect(a_request(:post, messages_url)).not_to have_been_made
    end

    it 'does nothing when there is no incoming message with a WhatsApp id' do
      incoming.update!(source_id: nil)

      expect(described_class.typing_on(conversation)).to be(false)
      expect(a_request(:post, messages_url)).not_to have_been_made
    end

    it 'does nothing when switched off with SHEKEL_WHATSAPP_TYPING_INDICATOR_ENABLED=false' do
      with_modified_env SHEKEL_WHATSAPP_TYPING_INDICATOR_ENABLED: 'false' do
        expect(described_class.typing_on(conversation)).to be(false)
      end
      expect(a_request(:post, messages_url)).not_to have_been_made
    end

    it 'does nothing for the 360dialog provider' do
      channel = create(:channel_whatsapp, provider: 'default', validate_provider_config: false, sync_templates: false)
      other = create(:conversation, inbox: channel.inbox, account: channel.inbox.account)
      create(:message, conversation: other, account: channel.inbox.account, inbox: channel.inbox, message_type: :incoming, source_id: 'wamid.x')

      expect(described_class.typing_on(other)).to be(false)
      expect(a_request(:post, messages_url)).not_to have_been_made
    end

    it 'does nothing for a non-WhatsApp inbox' do
      web = create(:conversation)
      create(:message, conversation: web, account: web.account, inbox: web.inbox, message_type: :incoming, source_id: 'x')

      expect(described_class.typing_on(web)).to be(false)
      expect(a_request(:post, messages_url)).not_to have_been_made
    end

    it 'returns false, logs only labels and does not raise when Meta fails' do
      stub_request(:post, messages_url).to_return(status: 400, body: { error: { code: 131_009, message: 'secret text' } }.to_json,
                                                  headers: json_headers)
      allow(Rails.logger).to receive(:warn)

      expect(described_class.typing_on(conversation)).to be(false)
      expect(Rails.logger).to have_received(:warn).with('[WHATSAPP_SIGNAL] typing_indicator failed http_status=400 meta_error_code=131009')
    end

    it 'returns false and does not raise on a timeout' do
      stub_request(:post, messages_url).to_timeout

      expect(described_class.typing_on(conversation)).to be(false)
    end
  end

  describe '.enqueue_typing' do
    it 'enqueues the job for a WhatsApp Cloud conversation' do
      expect { described_class.enqueue_typing(conversation) }
        .to have_enqueued_job(Shekel::WhatsappSeenSignalJob).with(conversation.id)
    end

    it 'enqueues nothing for other channels' do
      expect { described_class.enqueue_typing(create(:conversation)) }.not_to have_enqueued_job(Shekel::WhatsappSeenSignalJob)
    end
  end

  describe '.react' do
    let(:reaction_response) { { messaging_product: 'whatsapp', messages: [{ id: 'wamid.reaction' }] }.to_json }

    before do
      stub_request(:post, messages_url).to_return(status: 200, body: reaction_response, headers: json_headers)
      Redis::Alfred.delete("SHEKEL::WHATSAPP_REACTION::#{incoming.id}")
    end

    after { Redis::Alfred.delete("SHEKEL::WHATSAPP_REACTION::#{incoming.id}") }

    it 'reacts only once to the same message' do
      expect(described_class.react(conversation, incoming, '👀')).to be(true)
      expect(described_class.react(conversation, incoming, '👀')).to be(false)

      expect(a_request(:post, messages_url)).to have_been_made.once
    end

    it 'sends a reaction to the incoming message' do
      expect(described_class.react(conversation, incoming, '👀')).to be(true)

      expect(a_request(:post, messages_url).with do |req|
        body = JSON.parse(req.body)
        body['type'] == 'reaction' && body['to'] == conversation.contact_inbox.source_id &&
          body['reaction'] == { 'message_id' => 'wamid.incoming', 'emoji' => '👀' }
      end).to have_been_made.once
    end

    it 'refuses an outgoing message, an old message, a closed window and a bad emoji' do
      outgoing = create(:message, conversation: conversation, account: inbox.account, inbox: inbox, message_type: :outgoing, source_id: 'wamid.out')

      expect(described_class.reaction_problem(conversation, outgoing, '👀')).to eq(:message_not_found)
      expect(described_class.reaction_problem(conversation, nil, '👀')).to eq(:message_not_found)
      expect(described_class.reaction_problem(conversation, incoming, '')).to eq(:invalid_emoji)
      expect(described_class.reaction_problem(conversation, incoming, 'x' * 17)).to eq(:invalid_emoji)
      incoming.update!(created_at: 25.hours.ago)
      expect(described_class.reaction_problem(conversation, incoming, '👀')).to eq(:outside_messaging_window)
      incoming.update!(created_at: 30.days.ago)
      expect(described_class.reaction_problem(conversation, incoming, '👀')).to eq(:message_too_old)
      expect(a_request(:post, messages_url)).not_to have_been_made
    end
  end
end
