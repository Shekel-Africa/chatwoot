require 'rails_helper'

RSpec.describe 'Conversation reactions API', type: :request do
  let(:whatsapp_channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }
  let(:inbox) { whatsapp_channel.inbox }
  let(:account) { inbox.account }
  let(:conversation) { create(:conversation, inbox: inbox, account: account) }
  let(:incoming) do
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, source_id: 'wamid.incoming')
  end
  let(:agent_bot) { create(:agent_bot, account: account) }
  let(:url) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/reactions" }

  before { stub_request(:get, %r{graph.facebook.com/v14.0/.*message_templates}) }

  it 'returns unauthorized without credentials' do
    post url, params: { message_id: incoming.id, emoji: '👀' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  context 'when it is the agent bot on the inbox' do
    before { create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot) }

    it 'queues the reaction' do
      expect do
        post url, headers: { api_access_token: agent_bot.access_token.token }, params: { message_id: incoming.id, emoji: '👀' }, as: :json
      end.to have_enqueued_job(Shekel::WhatsappSeenSignalJob).with(conversation.id, incoming.id, '👀')

      expect(response).to have_http_status(:accepted)
    end

    it 'answers 422 with the reason and queues nothing for an outgoing message' do
      outgoing = create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, source_id: 'wamid.out')

      expect do
        post url, headers: { api_access_token: agent_bot.access_token.token }, params: { message_id: outgoing.id, emoji: '👀' }, as: :json
      end.not_to have_enqueued_job(Shekel::WhatsappSeenSignalJob)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('message_not_found')
    end
  end

  context 'when the inbox is not WhatsApp Cloud' do
    it 'answers 422 unsupported_channel' do
      web_conversation = create(:conversation, account: account)
      message = create(:message, conversation: web_conversation, account: account, inbox: web_conversation.inbox,
                                 message_type: :incoming, source_id: 'x')
      bot = create(:agent_bot, account: account)
      create(:agent_bot_inbox, inbox: web_conversation.inbox, agent_bot: bot)

      post "/api/v1/accounts/#{account.id}/conversations/#{web_conversation.display_id}/reactions",
           headers: { api_access_token: bot.access_token.token }, params: { message_id: message.id, emoji: '👀' }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('unsupported_channel')
    end
  end
end
