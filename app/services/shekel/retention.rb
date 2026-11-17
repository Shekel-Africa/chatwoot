# Shekel fork: conversation retention (Nigeria NDPA, Kenya Data Protection Act).
#
# - A conversation only Shailoq (the agent bot) and the contact took part in is
#   deleted BOT_ONLY_DAYS after its last activity.
# - A conversation a person took part in (a staff reply or private note, or a
#   reply from the WhatsApp Business app) is deleted WITH_PERSON_MONTHS after
#   its last activity.
# - A conversation snoozed into the future is skipped.
#
# Only conversations are selected. Contacts stay, and the audit log
# (shekel_audit_events) is never touched. Each conversation is deleted by its
# own upstream DeleteObjectJob (queue low). Each run records one
# `retention.purged` audit event with the counts.
#
# SHEKEL_RETENTION_DRY_RUN (default true) counts and audits without deleting.
# See docs/shekel/OPERATIONS.md.
class Shekel::Retention
  BOT_ONLY_DAYS = 30
  WITH_PERSON_MONTHS = 12
  BATCH_SIZE = 500

  OUTGOING = Message.message_types[:outgoing]

  # A person took part: an outgoing message or a private note from a staff
  # User, or a reply sent from the WhatsApp Business app (stored as an outgoing
  # echo with no sender). Notes from Shailoq, automations, macros or the system
  # do not count. content_attributes is a json column holding a JSON-encoded
  # string (ActiveRecord::Store), hence the #>> '{}' unwrap, as in
  # Message.not_forwarded.
  PERSON_MESSAGE_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM messages
      WHERE messages.conversation_id = conversations.id
        AND ((messages.sender_type = 'User' AND messages.message_type = #{OUTGOING})
             OR (messages.sender_type = 'User' AND messages.private = TRUE)
             OR (messages.message_type = #{OUTGOING}
                 AND (messages.content_attributes #>> '{}')::jsonb ->> 'external_echo' = 'true'))
    )
  SQL

  def self.bot_only_days
    Integer(ENV.fetch('SHEKEL_RETENTION_BOT_ONLY_DAYS', BOT_ONLY_DAYS))
  end

  def self.with_person_months
    Integer(ENV.fetch('SHEKEL_RETENTION_WITH_PERSON_MONTHS', WITH_PERSON_MONTHS))
  end

  def self.dry_run?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('SHEKEL_RETENTION_DRY_RUN', 'true').presence || 'true')
  end

  def initialize(now: Time.current)
    @now = now
    @bot_only_cutoff = now - self.class.bot_only_days.days
    @with_person_cutoff = now - self.class.with_person_months.months
    @dry_run = self.class.dry_run?
  end

  def perform
    counts = { bot_only: 0, with_person: 0 }
    Account.find_each do |account|
      counts[:bot_only] += purge(bot_only_scope(account))
      counts[:with_person] += purge(with_person_scope(account))
    end
    report(counts)
    counts
  end

  def bot_only_scope(account)
    candidates(account).where(last_activity_at: ...@bot_only_cutoff).where.not(PERSON_MESSAGE_SQL)
  end

  def with_person_scope(account)
    candidates(account).where(last_activity_at: ...@with_person_cutoff).where(PERSON_MESSAGE_SQL)
  end

  # A conversation snoozed into the future is still in use.
  def candidates(account)
    account.conversations.where('conversations.snoozed_until IS NULL OR conversations.snoozed_until <= ?', @now)
  end

  private

  # The two scopes are disjoint (with or without a person) and each account is
  # visited once, so a conversation is enqueued at most once per run. One that
  # is still queued from yesterday may be enqueued again; the second job is
  # discarded once the first has deleted it (ApplicationJob discards on
  # ActiveJob::DeserializationError).
  def purge(scope)
    return scope.count if @dry_run

    count = 0
    scope.select(:id).find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each { |conversation| DeleteObjectJob.perform_later(conversation) }
      count += batch.size
    end
    count
  end

  def report(counts)
    Rails.logger.info(
      "Shekel retention#{' (dry run)' if @dry_run}: bot_only=#{counts[:bot_only]} with_person=#{counts[:with_person]} " \
      "bot_only_cutoff=#{@bot_only_cutoff.iso8601} with_person_cutoff=#{@with_person_cutoff.iso8601}"
    )
    Shekel::Audit.record(
      action: 'retention.purged', actor: nil, subject: nil, account: audit_account_id,
      metadata: {
        bot_only_enqueued: counts[:bot_only], with_person_enqueued: counts[:with_person],
        bot_only_cutoff: @bot_only_cutoff.iso8601, with_person_cutoff: @with_person_cutoff.iso8601,
        dry_run: @dry_run
      }
    )
  end

  # Filed under the Shekel staff account so its administrators can export it;
  # the counts cover every account.
  def audit_account_id
    Shekel::OidcSettings.account_id
  rescue KeyError, ArgumentError
    Rails.logger.warn('Shekel retention: SHEKEL_CHATWOOT_ACCOUNT_ID is not set; the retention.purged audit row has no account')
    nil
  end
end
