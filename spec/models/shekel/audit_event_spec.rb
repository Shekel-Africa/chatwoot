require 'rails_helper'

# Shekel fork: append-only audit log.
RSpec.describe Shekel::AuditEvent do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account) }

  def record_event(**overrides)
    Shekel::Audit.record(action: 'conversation.viewed', actor: agent, subject: conversation, account: account, **overrides)
  end

  it 'records the actor, subject, account, metadata and ip address' do
    event = record_event(metadata: { display_id: conversation.display_id }, ip: '203.0.113.7')

    expect(event).to be_persisted
    expect(event).to have_attributes(
      account_id: account.id, actor_type: 'User', actor_id: agent.id, action: 'conversation.viewed',
      subject_type: 'Conversation', subject_id: conversation.id, metadata: { 'display_id' => conversation.display_id }
    )
    expect(event.ip_address.to_s).to eq('203.0.113.7')
  end

  it 'update_and_delete_raise_at_the_database' do
    event = record_event
    rows = described_class.where(id: event.id)

    # Each statement in a savepoint: the refused one aborts the transaction.
    expect { described_class.transaction(requires_new: true) { rows.update_all(action: 'conversation.resolved') } } # rubocop:disable Rails/SkipsModelValidations
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { described_class.transaction(requires_new: true) { rows.delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect(event.reload.action).to eq('conversation.viewed')
  end

  it 'is read-only once created' do
    event = record_event

    expect(event).to be_readonly
    expect { event.update!(action: 'conversation.resolved') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'keeps only allow-listed id and status keys in metadata' do
    event = record_event(metadata: { display_id: 7, content: 'Hello there', email: 'someone@example.test', phone_number: '+2348000000000' })

    expect(event.metadata).to eq('display_id' => 7)
  end

  it 'rejects an unknown action' do
    expect { record_event(action: 'conversation.deleted') }.to raise_error(ArgumentError, /conversation.deleted/)
  end

  it 'never breaks the caller when the write fails' do
    allow(described_class).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect(record_event).to be_nil
  end
end
