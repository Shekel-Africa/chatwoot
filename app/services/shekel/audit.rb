# Shekel fork: writes the append-only audit log (Shekel::AuditEvent).
#
#   Shekel::Audit.record(action: 'conversation.viewed', actor: user, subject: conversation,
#                        account: account, metadata: { display_id: 7 }, ip: request.remote_ip)
#
# `actor` is a record (User, AgentBot, AutomationRule, ...), an
# `{ 'type' =>, 'id' => }` reference captured at dispatch (see
# Shekel::AuditContext), or nil for the system. Metadata keeps only the
# allow-listed id, status and filter keys below, so message content, emails and
# phone numbers can never reach the log.
#
# Recording never breaks the caller: a failed write is logged and reported, and
# nil is returned. The insert runs in a savepoint, so a failed write cannot
# abort a transaction the caller has open. An unknown action is a programming
# error and raises.
module Shekel::Audit
  METADATA_KEYS = %w[
    display_id message_id from_assignee_id to_assignee_id from_team_id to_team_id
    from_status to_status data_export_id data_type from to provider
    since until user_ids inbox_id team_id rating data_import_id kind
    bot_only_deleted with_person_deleted bot_only_cutoff with_person_cutoff dry_run
  ].freeze
  VIEW_THROTTLE = 1.hour
  REDIS_ERRORS = [Redis::BaseError, ConnectionPool::Error, ConnectionPool::TimeoutError].freeze

  module_function

  def record(action:, actor:, subject:, account:, metadata: {}, ip: nil) # rubocop:disable Metrics/ParameterLists
    raise ArgumentError, "unknown audit action #{action}" unless Shekel::AuditEvent::ACTIONS.include?(action)

    actor_type, actor_id = actor_reference(actor)
    write(action: action, actor_type: actor_type, actor_id: actor_id,
          subject_type: subject&.class&.polymorphic_name, subject_id: subject&.id,
          account_id: account.is_a?(Account) ? account.id : account,
          metadata: metadata.to_h.stringify_keys.slice(*METADATA_KEYS), ip_address: ip)
  end

  # conversation.viewed at most once per user per conversation per hour, gated
  # by a Redis key rather than a database read per request. The key is released
  # when the write fails, so the next view is not lost.
  def record_view(user:, conversation:, ip: nil)
    return if user.blank? || conversation.blank?

    key = view_throttle_key(user: user, conversation: conversation)
    return unless Redis::Alfred.set(key, 1, nx: true, ex: VIEW_THROTTLE.to_i)

    event = record(action: 'conversation.viewed', actor: user, subject: conversation, account: conversation.account_id,
                   metadata: { display_id: conversation.display_id }, ip: ip)
    Redis::Alfred.delete(key) if event.nil?
    event
  rescue *REDIS_ERRORS => e
    Rails.logger.error("Shekel audit: view throttle unavailable: #{e.class}: #{e.message}")
    nil
  end

  # A sign-out has already succeeded when this runs, so nothing here may raise.
  def record_sign_out(user:, ip:)
    record(action: 'staff.signed_out', actor: user, subject: user, account: home_account_id(user), ip: ip)
  rescue StandardError => e
    report(e, 'staff.signed_out')
  end

  # The account a sign-out is filed under: the Shekel staff account when the
  # user belongs to it, otherwise their first account.
  def home_account_id(user)
    account_ids = user.account_users.order(:id).pluck(:account_id)
    staff_account_id = begin
      Shekel::OidcSettings.account_id
    rescue KeyError, ArgumentError
      nil
    end
    account_ids.include?(staff_account_id) ? staff_account_id : account_ids.first
  end

  # Keyed by actor type too: an AgentBot and a User can share an id.
  def view_throttle_key(user:, conversation:)
    "SHEKEL::AUDIT::VIEWED::#{user.class.polymorphic_name}::#{user.id}::#{conversation.id}"
  end

  def write(attributes)
    Shekel::AuditEvent.transaction(requires_new: true) { Shekel::AuditEvent.create!(attributes) }
  rescue StandardError => e
    report(e, attributes[:action])
  end

  def report(error, action)
    Rails.logger.error("Shekel audit: could not record #{action}: #{error.class}: #{error.message}")
    ChatwootExceptionTracker.new(error).capture_exception
    nil
  end

  def actor_reference(actor)
    case actor
    when nil then [nil, nil]
    when Hash then [actor['type'] || actor[:type], actor['id'] || actor[:id]]
    else [actor.class.polymorphic_name, actor.id]
    end
  end
end
