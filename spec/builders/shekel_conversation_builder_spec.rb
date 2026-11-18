require 'rails_helper'

# Shekel fork: with lock_to_single_conversation, the conversation an agent is
# handed back must be one they can see (Shekel::ConversationVisibility).
describe ConversationBuilder do
  let(:account) { create(:account) }
  let(:sms_inbox) { create(:inbox, channel: create(:channel_sms, account: account), account: account, lock_to_single_conversation: true) }
  let(:api_inbox) { create(:inbox, channel: create(:channel_api, account: account), account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_sms_inbox) { create(:contact_inbox, contact: contact, inbox: sms_inbox) }
  let(:contact_api_inbox) { create(:contact_inbox, contact: contact, inbox: api_inbox) }
  let(:ng_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:ke_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:ng_agent) { create(:user, account: account, role: :agent) }

  before do
    allow(Shekel::OidcSettings).to receive(:staff_mode?).and_return(true)
    create(:team_member, team: ng_team, user: ng_agent)
    Current.user = ng_agent
  end

  after { Current.reset }

  def conversation_in(contact_inbox, team)
    create(:conversation, account: account, inbox: contact_inbox.inbox, contact: contact, contact_inbox: contact_inbox, team: team)
  end

  def build(contact_inbox)
    described_class.new(contact_inbox: contact_inbox, params: ActionController::Parameters.new({})).perform
  end

  it 'reuses the latest conversation the agent can see, not a later hidden one' do
    visible = conversation_in(contact_sms_inbox, ng_team)
    conversation_in(contact_sms_inbox, ke_team)

    expect { expect(build(contact_sms_inbox)).to eq(visible) }.not_to change(Conversation, :count)
  end

  it 'starts a new conversation when none in the inbox is visible to the agent' do
    conversation_in(contact_api_inbox, ng_team) # the contact is visible through another inbox
    hidden = conversation_in(contact_sms_inbox, ke_team)

    conversation = nil
    expect { conversation = build(contact_sms_inbox) }.to change(Conversation, :count).by(1)
    expect(conversation).not_to eq(hidden)
    expect(conversation.team_id).to eq(ng_team.id)
  end

  it 'reuses the latest conversation as upstream when staff mode is off' do
    allow(Shekel::OidcSettings).to receive(:staff_mode?).and_return(false)
    conversation_in(contact_sms_inbox, ng_team)
    latest = conversation_in(contact_sms_inbox, ke_team)

    expect(build(contact_sms_inbox)).to eq(latest)
  end
end
