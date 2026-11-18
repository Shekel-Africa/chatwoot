require 'rails_helper'

RSpec.describe Shekel::ConversationVisibility do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:ng_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:ke_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:ng_agent) { create(:user, account: account, role: :agent) }
  let(:ke_agent) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:ng_conversation) { create(:conversation, account: account, inbox: inbox, team: ng_team) }
  let!(:ke_conversation) { create(:conversation, account: account, inbox: inbox, team: ke_team) }
  let!(:unteamed_conversation) { create(:conversation, account: account, inbox: inbox, team: nil) }
  let(:enabled) { true }

  before do
    allow(Shekel::OidcSettings).to receive(:staff_mode?).and_return(enabled)
    [ng_agent, ke_agent].each { |agent| create(:inbox_member, user: agent, inbox: inbox) }
    create(:team_member, team: ng_team, user: ng_agent)
    create(:team_member, team: ke_team, user: ke_agent)
  end

  def scoped(user)
    described_class.scope(user: user, account: account, relation: account.conversations)
  end

  describe '.scope' do
    it 'keeps an agent to their teams and their assigned conversations' do
      ke_conversation.update!(assignee: ng_agent)

      expect(scoped(ng_agent)).to contain_exactly(ng_conversation, ke_conversation)
    end

    it 'ignores teams of other accounts' do
      other_team = create(:team, account: create(:account))
      create(:team_member, team: other_team, user: ke_agent)

      expect(scoped(ke_agent)).to contain_exactly(ke_conversation)
    end

    it 'returns the relation unchanged for an administrator' do
      expect(scoped(admin)).to contain_exactly(ng_conversation, ke_conversation, unteamed_conversation)
    end

    it 'returns the relation unchanged for an agent bot' do
      relation = account.conversations
      expect(described_class.scope(user: create(:agent_bot), account: account, relation: relation)).to equal(relation)
    end

    it 'memoises the requesting user only for the current request' do
      Current.user = ng_agent
      expect(scoped(ng_agent)).to contain_exactly(ng_conversation)
      ng_team.remove_members([ng_agent.id])
      expect(scoped(ng_agent)).to contain_exactly(ng_conversation)

      Current.user = User.find(ng_agent.id)
      expect(scoped(ng_agent)).to be_empty
    ensure
      Current.reset
    end

    context 'when staff mode is off' do
      let(:enabled) { false }

      it 'returns the relation unchanged' do
        relation = account.conversations
        expect(described_class.scope(user: ng_agent, account: account, relation: relation)).to equal(relation)
      end
    end

    context 'when staff mode is on but Shekel sign-in is not configured' do
      before { allow(Shekel::OidcSettings).to receive(:enabled?).and_return(false) }

      it 'still keeps an agent to their teams' do
        expect(scoped(ng_agent)).to contain_exactly(ng_conversation)
      end
    end
  end

  describe '.scope_messages' do
    it 'keeps an agent to messages of visible conversations' do
      ng_message = create(:message, conversation: ng_conversation, account: account, inbox: inbox)
      create(:message, conversation: ke_conversation, account: account, inbox: inbox)

      expect(described_class.scope_messages(user: ng_agent, account: account, relation: account.messages)).to contain_exactly(ng_message)
    end
  end

  describe '.visible?' do
    it 'applies the team and assignee rule to agents' do
      expect(described_class.visible?(user: ng_agent, conversation: ng_conversation)).to be(true)
      expect(described_class.visible?(user: ng_agent, conversation: ke_conversation)).to be(false)
      expect(described_class.visible?(user: ng_agent, conversation: unteamed_conversation)).to be(false)

      unteamed_conversation.update!(assignee: ng_agent)
      expect(described_class.visible?(user: ng_agent, conversation: unteamed_conversation)).to be(true)
    end

    it 'lets administrators and agent bots see everything' do
      expect(described_class.visible?(user: admin, conversation: unteamed_conversation)).to be(true)
      expect(described_class.visible?(user: create(:agent_bot), conversation: ke_conversation)).to be(true)
    end
  end

  describe '.creation_defaults' do
    it 'uses the loaded Current.account instead of looking the account up again' do
      Current.account = account
      allow(Account).to receive(:find).and_call_original

      defaults = described_class.creation_defaults(user: ng_agent, attributes: { account_id: account.id, team_id: nil, assignee_id: nil })

      expect(defaults).to eq(team_id: ng_team.id)
      expect(Account).not_to have_received(:find)
    ensure
      Current.reset
    end
  end

  describe '.recipients' do
    it 'keeps the conversation team, the assignee and administrators' do
      unteamed_conversation.update!(assignee: ke_agent)
      users = User.where(id: [ng_agent.id, ke_agent.id, admin.id])

      expect(described_class.recipients(conversation: ng_conversation, users: users)).to contain_exactly(ng_agent, admin)
      expect(described_class.recipients(conversation: unteamed_conversation, users: users)).to contain_exactly(ke_agent, admin)
    end
  end

  describe '.lost_audience' do
    it 'names the agents of the previous team and the previous assignee only' do
      ng_conversation.update!(assignee: ng_agent)
      ng_conversation.update!(team: ke_team, assignee: nil)

      lost = described_class.lost_audience(conversation: ng_conversation, changed_attributes: ng_conversation.previous_changes)
      expect(lost).to contain_exactly(ng_agent)
    end
  end

  describe 'hooks' do
    it 'tells agents who lost a conversation to drop it' do
      ng_conversation.update!(team: ke_team)
      event = Events::Base.new(:'team.changed', Time.zone.now, conversation: ng_conversation,
                                                               changed_attributes: ng_conversation.previous_changes)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      ActionCableListener.instance.team_changed(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later)
        .with([ng_agent.pubsub_token], described_class::HIDDEN_EVENT, { id: ng_conversation.display_id, account_id: account.id })
      expect(ActionCableBroadcastJob).to have_received(:perform_later)
        .with(satisfy { |tokens| tokens.include?(ke_agent.pubsub_token) && tokens.exclude?(ng_agent.pubsub_token) }, 'team.changed', anything)
    end

    it 'sends contact events only to administrators and agents who can see the contact' do
      event = Events::Base.new(:'contact.updated', Time.zone.now, contact: ke_conversation.contact)
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *|
        expect(tokens).to contain_exactly(ke_agent.pubsub_token, admin.pubsub_token)
      end

      ActionCableListener.instance.contact_updated(event)
    end

    it 'broadcasts conversation events only to agents who can see the conversation' do
      event = Events::Base.new(:'conversation.updated', Time.zone.now, conversation: ng_conversation)
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *|
        expect(tokens).to include(ng_agent.pubsub_token, admin.pubsub_token)
        expect(tokens).not_to include(ke_agent.pubsub_token)
      end

      ActionCableListener.instance.conversation_updated(event)
    end

    it 'broadcasts messages only to agents who can see the conversation' do
      message = create(:message, conversation: ke_conversation, account: account, inbox: inbox)
      event = Events::Base.new(:'message.created', Time.zone.now, message: message)
      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, *|
        expect(tokens).to include(ke_agent.pubsub_token)
        expect(tokens).not_to include(ng_agent.pubsub_token)
      end

      ActionCableListener.instance.message_created(event)
    end

    it 'does not let an agent be mentioned in a conversation they cannot see' do
      content = "(mention://user/#{ng_agent.id}/ng) (mention://user/#{ke_agent.id}/ke)"
      message = create(:message, conversation: ke_conversation, account: account, inbox: inbox, private: true, content: content)

      expect(Conversations::UserMentionJob).to receive(:perform_later).with([ke_agent.id.to_s], ke_conversation.id, account.id)
      Messages::MentionService.new(message: message).perform
    end

    it 'does not notify an agent about a conversation they cannot see' do
      notification = NotificationBuilder.new(notification_type: 'conversation_mention', user: ng_agent, account: account,
                                             primary_actor: ke_conversation).perform

      expect(notification).to be_nil
      expect(ng_agent.notifications).to be_empty
    end
  end
end
