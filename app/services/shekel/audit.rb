# Shekel fork: writes the append-only audit log (Shekel::AuditEvent).
#
#   Shekel::Audit.record(action: 'conversation.viewed', actor: user, subject: conversation,
#                        account: account, metadata: { display_id: 7 }, ip: request.remote_ip)
#
# `actor` is a record (User, AgentBot, AutomationRule, ...), an
# `{ 'type' =>, 'id' => }` reference captured at dispatch (see
# Shekel::AuditContext), or nil for the system. Metadata keeps only the
# allow-listed id and status keys below, so message content, emails and phone
# numbers can never reach the log.
#
# Recording never breaks the caller: a failed write is logged and reported, and
# nil is returned. An unknown action is a programming error and raises.
module Shekel::Audit
  METADATA_KEYS = %w[
    display_id message_id from_assignee_id to_assignee_id from_team_id to_team_id
    from_status to_status data_export_id data_type from to provider
  ].freeze
  VIEW_THROTTLE = 1.hour

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
  # by a Redis key rather than a database read per request.
  def record_view(user:, conversation:, ip: nil)
    return if user.blank? || conversation.blank?
    return unless Redis::Alfred.set(view_throttle_key(user: user, conversation: conversation), 1, nx: true, ex: VIEW_THROTTLE.to_i)

    record(action: 'conversation.viewed', actor: user, subject: conversation, account: conversation.account_id,
           metadata: { display_id: conversation.display_id }, ip: ip)
  rescue Redis::BaseError => e
    Rails.logger.error("Shekel audit: view throttle unavailable: #{e.message}")
    nil
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

  def view_throttle_key(user:, conversation:)
    "SHEKEL::AUDIT::VIEWED::#{user.id}::#{conversation.id}"
  end

  def write(attributes)
    Shekel::AuditEvent.create!(attributes)
  rescue StandardError => e
    Rails.logger.error("Shekel audit: could not record #{attributes[:action]}: #{e.class}: #{e.message}")
    ChatwootExceptionTracker.new(e).capture_exception
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
