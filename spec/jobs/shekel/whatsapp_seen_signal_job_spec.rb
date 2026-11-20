require 'rails_helper'

RSpec.describe Shekel::WhatsappSeenSignalJob do
  let(:conversation) { create(:conversation) }
  let(:message) { create(:message, conversation: conversation, account: conversation.account, inbox: conversation.inbox, message_type: :incoming) }

  before do
    allow(Shekel::WhatsappSeenSignal).to receive(:typing_on)
    allow(Shekel::WhatsappSeenSignal).to receive(:react)
  end

  it 'is queued on the high queue' do
    expect(described_class.new.queue_name).to eq('high')
  end

  it 'sends the typing indicator when given only a conversation' do
    described_class.perform_now(conversation.id)

    expect(Shekel::WhatsappSeenSignal).to have_received(:typing_on).with(conversation)
  end

  it 'sends a reaction when given a message and an emoji' do
    described_class.perform_now(conversation.id, message.id, '👀')

    expect(Shekel::WhatsappSeenSignal).to have_received(:react).with(conversation, message, '👀')
  end

  it 'ignores a conversation that no longer exists' do
    described_class.perform_now(0)

    expect(Shekel::WhatsappSeenSignal).not_to have_received(:typing_on)
  end
end
