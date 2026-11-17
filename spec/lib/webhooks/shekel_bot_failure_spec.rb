require 'rails_helper'

# Shekel fork: a bot outage (Shailoq gateway down) must hand the conversation to a person.
RSpec.describe Webhooks::Trigger do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let!(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }
  let(:url) { 'https://shailoq-gateway.example.com/webhook' }
  let(:payload) { { event: 'message_created', id: message.id } }
  let(:activity_content) { I18n.t('conversations.activity.agent_bot.error_moved_to_open') }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('shailoq-gateway.example.com').and_return(['93.184.216.34'])
  end

  after do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def deliver
    perform_enqueued_jobs do
      AgentBots::WebhookJob.perform_later(url, payload, :agent_bot_webhook)
    end
  end

  def expect_handed_to_a_person
    expect(conversation.reload.status).to eq('open')
    activity = conversation.messages.where(message_type: :activity).order(:created_at).last
    expect(activity.content).to eq(activity_content)
  end

  it 'returns_500_after_retries_moves_to_open_with_the_activity_note' do
    stub = stub_request(:post, url).to_return(status: 500)
    deliver
    expect(stub).to have_been_requested.times(3)
    expect_handed_to_a_person
  end

  it 'times_out_moves_to_open' do
    stub = stub_request(:post, url).to_timeout
    deliver
    expect(stub).to have_been_requested.at_least_once
    expect_handed_to_a_person
  end

  it 'is_refused_at_connection_moves_to_open' do
    stub = stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
    deliver
    expect(stub).to have_been_requested.at_least_once
    expect_handed_to_a_person
  end

  it 'returns_401_moves_to_open' do
    stub = stub_request(:post, url).to_return(status: 401)
    deliver
    expect(stub).to have_been_requested.once
    expect_handed_to_a_person
  end

  it 'a_conversation_already_open_is_unchanged' do
    conversation.update!(status: :open)
    stub_request(:post, url).to_return(status: 500)
    deliver
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.where(message_type: :activity)).to be_empty
  end
end
