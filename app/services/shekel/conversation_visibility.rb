# Shekel fork: an agent sees only the conversations of their teams.
#
# Shekel runs one WhatsApp inbox shared by every country, and every agent is a
# member of every inbox (Shekel::StaffSync), so upstream's inbox-based access
# would let every agent see every country. With Shekel sign-in enabled, an
# agent (any non-administrator) sees a conversation only when its team is one
# of their teams in that account or when it is assigned to them. Unteamed
# conversations are visible to administrators and the assignee only.
# Administrators are unaffected.
#
# Called from small `# Shekel fork:` hooks in the conversation list paths
# (Conversations::PermissionFilterService, SearchService), ConversationPolicy
# (every per-conversation endpoint and NotificationBuilder) and
# ActionCableListener (real-time events).
module Shekel::ConversationVisibility
  module_function

  # Narrows a conversations relation to what the user may see.
  def scope(user:, account:, relation:)
    return relation unless restricted?(user: user, account: account)

    table = Conversation.arel_table
    relation.where(table[:team_id].in(team_ids(user, account)).or(table[:assignee_id].eq(user.id)))
  end

  # Narrows a messages relation to messages of conversations the user may see.
  def scope_messages(user:, account:, relation:)
    return relation unless restricted?(user: user, account: account)

    relation.where(conversation_id: scope(user: user, account: account, relation: account.conversations).select(:id))
  end

  def visible?(user:, conversation:)
    return true unless user.is_a?(User)
    return true unless restricted?(user: user, account: conversation.account)
    return true if conversation.assignee_id == user.id
    return false if conversation.team_id.nil?

    team_ids(user, conversation.account).include?(conversation.team_id)
  end

  # True when the record is a conversation this rule hides from the user, so the
  # API answers 404 (as if it did not exist) instead of upstream's 401.
  def hidden?(record:, user:)
    record.is_a?(Conversation) && user.is_a?(User) && !visible?(user: user, conversation: record)
  end

  # Narrows a users relation (e.g. inbox members) to those who may see the conversation.
  def recipients(conversation:, users:)
    return users unless Shekel::OidcSettings.enabled?

    allowed = AccountUser.where(account_id: conversation.account_id, role: :administrator).pluck(:user_id)
    allowed << conversation.assignee_id if conversation.assignee_id
    allowed += TeamMember.where(team_id: conversation.team_id).pluck(:user_id) if conversation.team_id
    users.where(id: allowed)
  end

  def restricted?(user:, account:)
    return false unless Shekel::OidcSettings.enabled?

    !AccountUser.exists?(account_id: account.id, user_id: user.id, role: :administrator)
  end

  def team_ids(user, account)
    TeamMember.joins(:team).where(user_id: user.id, teams: { account_id: account.id }).pluck(:team_id)
  end
end
