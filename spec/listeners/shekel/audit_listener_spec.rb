require 'rails_helper'

# Shekel fork: the audit log's event-driven actions. The listener runs in
# EventDispatcherJob, so the actor comes from the payload: the message's sender,
# or the `shekel_audit` context captured at dispatch (Shekel::AuditContext).
RSpec.describe Shekel::AuditListener do
  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  def event(name, **data)
    Events::Base.new(name, Time.zone.now, data)
  end

  def captured(actor, **extra)
    { 'actor_type' => actor.class.polymorphic_name, 'actor_id' => actor.id }.merge(extra.stringify_keys)
  end

  def audit_events(action)
    Shekel::AuditEvent.where(action: action)
  end

  it 'is registered with the async dispatcher' do
    expect(AsyncDispatcher.new.listeners).to include(described_class.instance)
  end

  describe 'conversation.replied' do
    it 'records an outgoing public message sent by a user' do
      message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent)

      listener.message_created(event('message.created', message: message, performed_by: nil))

      expect(audit_events('conversation.replied').sole).to have_attributes(
        account_id: account.id, actor_type: 'User', actor_id: agent.id, subject_type: 'Conversation', subject_id: conversation.id,
        metadata: { 'message_id' => message.id, 'display_id' => conversation.display_id }, ip_address: nil
      )
    end

    it 'metadata_never_contains_message_content' do
      message = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent,
                                 content: 'Your loan is approved, call 000-FAKE-0000')

      listener.message_created(event('message.created', message: message))

      stored = Shekel::AuditEvent.sole.attributes.values.map(&:to_s).join(' ')
      expect(stored).not_to include('approved')
      expect(stored).not_to include('000-FAKE-0000')
    end

    it 'bot_replies_are_not_recorded_as_staff_replies' do
      bot = create(:agent_bot, account: account)
      bot_reply = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: bot)
      system_reply = create(:message, :bot_message, account: account, inbox: inbox, conversation: conversation)

      listener.message_created(event('message.created', message: bot_reply, performed_by: bot))
      listener.message_created(event('message.created', message: system_reply))

      expect(Shekel::AuditEvent.count).to eq(0)
    end

    it 'does not record incoming or activity messages' do
      incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
      activity = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :activity, sender: nil)

      listener.message_created(event('message.created', message: incoming))
      listener.message_created(event('message.created', message: activity))

      expect(Shekel::AuditEvent.count).to eq(0)
    end
  end

  describe 'conversation.note_added' do
    it 'records a private note by a user' do
      note = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, private: true, sender: agent)

      listener.message_created(event('message.created', message: note))

      expect(audit_events('conversation.note_added').sole).to have_attributes(actor_id: agent.id, subject_id: conversation.id,
                                                                              metadata: { 'message_id' => note.id,
                                                                                          'display_id' => conversation.display_id })
      expect(audit_events('conversation.replied')).to be_empty
    end
  end

  describe 'conversation.assigned' do
    it 'records the previous and new assignee' do
      changes = { 'assignee_id' => [other_agent.id, agent.id] }
      listener.assignee_changed(event('assignee.changed', conversation: conversation, changed_attributes: changes,
                                                          shekel_audit: captured(agent)))

      expect(audit_events('conversation.assigned').sole).to have_attributes(
        actor_type: 'User', actor_id: agent.id, subject_id: conversation.id,
        metadata: { 'display_id' => conversation.display_id, 'from_assignee_id' => other_agent.id, 'to_assignee_id' => agent.id }
      )
    end

    it 'falls back to the automation that made the change' do
      rule = create(:automation_rule, account: account)

      listener.assignee_changed(event('assignee.changed', conversation: conversation, changed_attributes: { 'assignee_id' => [nil, agent.id] },
                                                          performed_by: rule))

      expect(audit_events('conversation.assigned').sole).to have_attributes(actor_type: 'AutomationRule', actor_id: rule.id)
    end

    it 'ignores agent bot assignment changes' do
      listener.assignee_changed(event('assignee.changed', conversation: conversation, changed_attributes: { 'assignee_agent_bot_id' => [nil, 1] }))

      expect(Shekel::AuditEvent.count).to eq(0)
    end
  end

  describe 'conversation.team_changed' do
    it 'records the previous and new team' do
      team = create(:team, account: account)

      listener.team_changed(event('team.changed', conversation: conversation, changed_attributes: { 'team_id' => [nil, team.id] },
                                                  shekel_audit: captured(agent)))

      expect(audit_events('conversation.team_changed').sole).to have_attributes(
        actor_id: agent.id, metadata: { 'display_id' => conversation.display_id, 'from_team_id' => nil, 'to_team_id' => team.id }
      )
    end
  end

  describe 'conversation.resolved' do
    it 'records who resolved the conversation' do
      listener.conversation_resolved(event('conversation.resolved', conversation: conversation,
                                                                    shekel_audit: captured(agent, from_status: 'open')))

      expect(audit_events('conversation.resolved').sole).to have_attributes(
        actor_id: agent.id, metadata: { 'display_id' => conversation.display_id, 'from_status' => 'open', 'to_status' => 'resolved' }
      )
    end
  end

  describe 'conversation.reopened' do
    it 'records who reopened the conversation' do
      listener.conversation_opened(event('conversation.opened', conversation: conversation,
                                                                shekel_audit: captured(agent, from_status: 'resolved')))

      expect(audit_events('conversation.reopened').sole).to have_attributes(
        actor_id: agent.id, metadata: { 'display_id' => conversation.display_id, 'from_status' => 'resolved', 'to_status' => 'open' }
      )
    end

    it 'records a system reopen without an actor' do
      listener.conversation_opened(event('conversation.opened', conversation: conversation, shekel_audit: { 'from_status' => 'snoozed' }))

      expect(audit_events('conversation.reopened').sole).to have_attributes(actor_type: nil, actor_id: nil)
    end
  end

  describe 'end to end through the dispatcher' do
    after { Current.reset }

    it 'records the signed-in user captured at dispatch, not at job time' do
      Current.user = agent
      conversation.update!(status: :resolved)
      Current.reset

      perform_enqueued_jobs(only: EventDispatcherJob)

      expect(audit_events('conversation.resolved').sole).to have_attributes(actor_type: 'User', actor_id: agent.id,
                                                                            metadata: include('from_status' => 'open'))
    end
  end
end
