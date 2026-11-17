require 'rails_helper'

# Shekel fork: conversation retention (spec §8). Bot-only conversations go after
# 30 days of inactivity, conversations a person took part in after 12 months.
RSpec.describe Shekel::Retention do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:bot) { create(:agent_bot, account: account) }

  def conversation_inactive_for(duration)
    create(:conversation, account: account, inbox: inbox).tap do |conversation|
      yield conversation if block_given?
      conversation.update_columns(last_activity_at: duration.ago) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def add_message(conversation, **attributes)
    create(:message, account: account, inbox: inbox, conversation: conversation, **attributes)
  end

  def bot_only(conversation)
    add_message(conversation, message_type: :incoming, sender: conversation.contact)
    add_message(conversation, message_type: :outgoing, sender: bot)
    add_message(conversation, message_type: :activity, sender: nil, content: 'Conversation was resolved')
  end

  def run_retention(dry_run: 'false', **env)
    with_modified_env(SHEKEL_RETENTION_DRY_RUN: dry_run, **env) { described_class.new.perform }
  end

  def enqueued_deletions
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job['job_class'] == 'DeleteObjectJob' }
  end

  it 'deletes_a_bot_only_conversation_inactive_for_31_days' do
    conversation = conversation_inactive_for(31.days) { |c| bot_only(c) }

    expect { run_retention }.to have_enqueued_job(DeleteObjectJob).with(conversation).on_queue('low')
  end

  it 'keeps_a_bot_only_conversation_inactive_for_29_days' do
    conversation_inactive_for(29.days) { |c| bot_only(c) }

    expect { run_retention }.not_to have_enqueued_job(DeleteObjectJob)
  end

  it 'keeps_a_conversation_a_person_replied_to_31_days_ago' do
    conversation_inactive_for(31.days) do |c|
      bot_only(c)
      add_message(c, message_type: :outgoing, sender: agent)
    end

    expect { run_retention }.not_to have_enqueued_job(DeleteObjectJob)
  end

  it 'keeps_a_conversation_with_a_private_note_inactive_for_31_days' do
    conversation_inactive_for(31.days) do |c|
      bot_only(c)
      # Any private note counts, whoever wrote it.
      add_message(c, message_type: :outgoing, private: true, sender: bot)
    end

    expect { run_retention }.not_to have_enqueued_job(DeleteObjectJob)
  end

  it 'deletes_a_with_person_conversation_inactive_for_13_months' do
    conversation = conversation_inactive_for(13.months) { |c| add_message(c, message_type: :outgoing, sender: agent) }

    expect { run_retention }.to have_enqueued_job(DeleteObjectJob).with(conversation)
  end

  it 'keeps_a_with_person_conversation_inactive_for_11_months' do
    conversation_inactive_for(11.months) { |c| add_message(c, message_type: :outgoing, sender: agent) }

    expect { run_retention }.not_to have_enqueued_job(DeleteObjectJob)
  end

  it 'contact_only_messages_do_not_count_as_a_person' do
    conversation = conversation_inactive_for(31.days) do |c|
      add_message(c, message_type: :incoming, sender: c.contact)
      add_message(c, message_type: :incoming, sender: c.contact)
    end

    expect { run_retention }.to have_enqueued_job(DeleteObjectJob).with(conversation)
  end

  it 'records_one_audit_event_with_counts' do
    conversation_inactive_for(31.days) { |c| bot_only(c) }
    conversation_inactive_for(40.days) { |c| bot_only(c) }
    conversation_inactive_for(13.months) { |c| add_message(c, message_type: :outgoing, sender: agent) }
    conversation_inactive_for(1.day) { |c| bot_only(c) }

    expect { run_retention }.to change(Shekel::AuditEvent, :count).by(1)

    event = Shekel::AuditEvent.last
    expect(event).to have_attributes(action: 'retention.purged', actor_type: nil, actor_id: nil, subject_type: nil)
    expect(event.metadata).to include('bot_only_deleted' => 2, 'with_person_deleted' => 1, 'dry_run' => false)
    expect(Time.zone.parse(event.metadata['bot_only_cutoff'])).to be_within(1.minute).of(30.days.ago)
    expect(Time.zone.parse(event.metadata['with_person_cutoff'])).to be_within(1.minute).of(12.months.ago)
  end

  it 'covers_every_account_and_enqueues_each_conversation_once' do
    other_account = create(:account)
    other_inbox = create(:inbox, account: other_account)
    mine = conversation_inactive_for(31.days) { |c| bot_only(c) }
    theirs = create(:conversation, account: other_account, inbox: other_inbox)
    theirs.update_columns(last_activity_at: 31.days.ago) # rubocop:disable Rails/SkipsModelValidations

    run_retention

    expect(enqueued_deletions.map { |job| job['arguments'].first['_aj_globalid'] })
      .to contain_exactly(mine.to_global_id.to_s, theirs.to_global_id.to_s)
  end

  it 'dry_run_counts_and_audits_without_enqueuing' do
    conversation_inactive_for(31.days) { |c| bot_only(c) }

    expect { run_retention(dry_run: 'true') }.not_to have_enqueued_job(DeleteObjectJob)
    expect(Shekel::AuditEvent.last.metadata).to include('bot_only_deleted' => 1, 'with_person_deleted' => 0, 'dry_run' => true)
  end

  it 'is_a_dry_run_unless_turned_off' do
    conversation_inactive_for(31.days) { |c| bot_only(c) }

    with_modified_env(SHEKEL_RETENTION_DRY_RUN: nil) do
      expect { described_class.new.perform }.not_to have_enqueued_job(DeleteObjectJob)
    end
  end

  it 'reads_the_periods_from_the_environment' do
    conversation = conversation_inactive_for(8.days) { |c| bot_only(c) }

    expect { run_retention(SHEKEL_RETENTION_BOT_ONLY_DAYS: '7', SHEKEL_RETENTION_WITH_PERSON_MONTHS: '6') }
      .to have_enqueued_job(DeleteObjectJob).with(conversation)
  end

  it 'never_touches_contacts_or_the_audit_log' do
    conversation = conversation_inactive_for(31.days) { |c| bot_only(c) }
    contact = conversation.contact
    earlier = Shekel::Audit.record(action: 'conversation.viewed', actor: agent, subject: conversation, account: account)

    perform_enqueued_jobs { run_retention }

    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(Contact.exists?(contact.id)).to be(true)
    expect(Shekel::AuditEvent.exists?(earlier.id)).to be(true)
  end
end
