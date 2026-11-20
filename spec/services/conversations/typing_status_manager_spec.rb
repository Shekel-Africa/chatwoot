require 'rails_helper'

RSpec.describe Conversations::TypingStatusManager do
  let(:conversation) { create(:conversation) }
  let(:agent) { create(:user, account: conversation.account) }

  before do
    allow(Rails.configuration.dispatcher).to receive(:dispatch)
    allow(Shekel::WhatsappSeenSignal).to receive(:enqueue_typing)
  end

  it 'asks for the WhatsApp seen signal when typing goes on' do
    described_class.new(conversation, agent, { typing_status: 'on', is_private: false }).toggle_typing_status

    expect(Shekel::WhatsappSeenSignal).to have_received(:enqueue_typing).with(conversation)
  end

  it 'does not send it when typing goes off' do
    described_class.new(conversation, agent, { typing_status: 'off' }).toggle_typing_status

    expect(Shekel::WhatsappSeenSignal).not_to have_received(:enqueue_typing)
  end

  it 'does not send it for private notes, however the flag is spelled' do
    [true, 'true'].each do |flag|
      described_class.new(conversation, agent, { typing_status: 'on', is_private: flag }).toggle_typing_status
    end

    expect(Shekel::WhatsappSeenSignal).not_to have_received(:enqueue_typing)
  end
end
