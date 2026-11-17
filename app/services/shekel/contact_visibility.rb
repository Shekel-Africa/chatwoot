# Shekel fork: an agent sees only the contacts of conversations they can see.
#
# Contacts (dealers) follow Shekel::ConversationVisibility: with Shekel sign-in
# enabled, an agent sees a contact only when at least one of the contact's
# conversations is visible to them. A contact with no conversation is visible
# to administrators only. Administrators and non-staff actors are unaffected.
#
# Called from `# Shekel fork:` hooks in the contacts controllers, contact
# search (SearchService), Contacts::FilterService, conversation creation and
# ActionCableListener (contact events).
module Shekel::ContactVisibility
  module_function

  # Narrows a contacts relation to what the user may see.
  def scope(user:, account:, relation:)
    return relation unless Shekel::ConversationVisibility.restricted?(user: user, account: account)

    relation.where(id: visible_conversations(user, account).select(:contact_id))
  end

  # The account's contacts the user may see.
  def contacts(user:, account:)
    scope(user: user, account: account, relation: account.contacts)
  end

  def visible?(user:, contact:)
    return true unless Shekel::ConversationVisibility.restricted?(user: user, account: contact.account)

    visible_conversations(user, contact.account).exists?(contact_id: contact.id)
  end

  # Pubsub tokens for a contact event, or nil to keep upstream's account-wide
  # stream: administrators plus the agents who can see one of its conversations.
  def event_tokens(account:, contact_id:)
    return unless Shekel::OidcSettings.enabled?

    conversations = account.conversations.where(contact_id: contact_id)
    user_ids = AccountUser.where(account_id: account.id, role: :administrator).pluck(:user_id)
    user_ids += conversations.where.not(assignee_id: nil).distinct.pluck(:assignee_id)
    user_ids += TeamMember.where(team_id: conversations.where.not(team_id: nil).select(:team_id)).pluck(:user_id)
    User.where(id: user_ids.uniq).pluck(:pubsub_token)
  end

  def visible_conversations(user, account)
    Shekel::ConversationVisibility.scope(user: user, account: account, relation: account.conversations)
  end
end
