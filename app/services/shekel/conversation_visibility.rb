# Shekel fork: an agent sees only the conversations of their teams.
#
# Shekel runs one WhatsApp inbox shared by every country, and every agent is a
# member of every inbox (Shekel::StaffSync), so upstream's inbox-based access
# would let every agent see every country. In staff mode
# (Shekel::OidcSettings.staff_mode?), an agent (any non-administrator) sees a
# conversation only when its team is one of their teams in that account or when
# it is assigned to them. Unteamed conversations are visible to administrators
# and the assignee only.
# Administrators are unaffected.
#
# Called from small `# Shekel fork:` hooks in the conversation list paths
# (Conversations::PermissionFilterService, SearchService, the unread counter),
# ConversationPolicy (every per-conversation endpoint and NotificationBuilder),
# conversation creation and ActionCableListener (real-time events).
# Contacts follow the same rule through Shekel::ContactVisibility.
#
# Only staff users are narrowed; agent bots and other actors are not. The role
# and team lookups for the requesting user are memoised on Current, which is
# reset at the end of every API request.
module Shekel::ConversationVisibility
  module_function

  # Sent to agents who can no longer see a conversation; the dashboard drops the row.
  HIDDEN_EVENT = 'shekel.conversation.hidden'.freeze

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
    return users unless Shekel::OidcSettings.staff_mode?

    users.where(id: audience_ids(conversation.account_id, conversation.team_id, conversation.assignee_id))
  end

  # Agents who could see the conversation before a team or assignee change and
  # cannot any more. `changed_attributes` is the conversation's previous_changes.
  def lost_audience(conversation:, changed_attributes:)
    return User.none unless Shekel::OidcSettings.staff_mode?

    changes = (changed_attributes || {}).with_indifferent_access
    previous_team_id = changes.key?(:team_id) ? changes[:team_id].first : conversation.team_id
    previous_assignee_id = changes.key?(:assignee_id) ? changes[:assignee_id].first : conversation.assignee_id
    before = audience_ids(conversation.account_id, previous_team_id, previous_assignee_id)
    after = audience_ids(conversation.account_id, conversation.team_id, conversation.assignee_id)
    User.where(id: before - after)
  end

  # Defaults for a conversation an agent starts, so it stays visible to them:
  # with no team, it goes to the agent's team when they have exactly one; if they
  # still could not see it and it has no assignee, it is assigned to them.
  # `attributes` are the new conversation's (account_id, team_id, assignee_id).
  def creation_defaults(user:, attributes:)
    return {} unless user.is_a?(User) && Shekel::OidcSettings.staff_mode?

    account = Current.account&.id == attributes[:account_id] ? Current.account : Account.find(attributes[:account_id])
    restricted?(user: user, account: account) ? agent_creation_defaults(user, account, attributes) : {}
  end

  def agent_creation_defaults(user, account, attributes)
    own_teams = team_ids(user, account)
    team_id = attributes[:team_id]
    defaults = {}
    defaults[:team_id] = team_id = own_teams.first if team_id.blank? && own_teams.one?
    defaults[:assignee_id] = user.id if attributes[:assignee_id].blank? && own_teams.exclude?(team_id.to_i)
    defaults
  end

  def restricted?(user:, account:)
    return false unless Shekel::OidcSettings.staff_mode? && user.is_a?(User)

    memo(user, [:restricted, account.id]) do
      !AccountUser.exists?(account_id: account.id, user_id: user.id, role: :administrator)
    end
  end

  def team_ids(user, account)
    memo(user, [:team_ids, account.id]) do
      TeamMember.joins(:team).where(user_id: user.id, teams: { account_id: account.id }).pluck(:team_id)
    end
  end

  def audience_ids(account_id, team_id, assignee_id)
    ids = AccountUser.where(account_id: account_id, role: :administrator).pluck(:user_id)
    ids << assignee_id if assignee_id
    ids += TeamMember.where(team_id: team_id).pluck(:user_id) if team_id
    ids.uniq
  end

  # Per-request memo for the requesting user only; other users are looked up
  # afresh. The memo is tied to the Current.user object, which each request loads
  # anew, so a thread that never resets Current cannot serve a stale answer.
  def memo(user, key)
    return yield unless Current.user.is_a?(User) && Current.user.id == user.id

    Current.shekel_visibility = { owner: Current.user.object_id } if Current.shekel_visibility&.dig(:owner) != Current.user.object_id
    cache = Current.shekel_visibility
    cache.key?(key) ? cache[key] : (cache[key] = yield)
  end
end
