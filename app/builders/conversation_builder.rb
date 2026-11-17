class ConversationBuilder
  pattr_initialize [:params!, :contact_inbox!]

  def perform
    # Shekel fork: an agent cannot reach a contact they cannot see (e.g. by its source id).
    raise ActiveRecord::RecordNotFound unless Shekel::ContactVisibility.visible?(user: Current.user, contact: @contact_inbox.contact)

    look_up_exising_conversation || create_new_conversation
  end

  private

  def look_up_exising_conversation
    return unless @contact_inbox.inbox.lock_to_single_conversation?

    @contact_inbox.conversations.last
  end

  def create_new_conversation
    attributes = conversation_params
    # Shekel fork: a conversation an agent starts stays visible to them (no-op unless Current.user is a staff agent).
    attributes.merge!(Shekel::ConversationVisibility.creation_defaults(user: Current.user, attributes: attributes))
    ::Conversation.create!(attributes)
  end

  def conversation_params
    additional_attributes = params[:additional_attributes]&.permit! || {}
    custom_attributes = params[:custom_attributes]&.permit! || {}
    status = params[:status].present? ? { status: params[:status] } : {}

    # TODO: temporary fallback for the old bot status in conversation, we will remove after couple of releases
    # commenting this out to see if there are any errors, if not we can remove this in subsequent releases
    # status = { status: 'pending' } if status[:status] == 'bot'
    {
      account_id: @contact_inbox.inbox.account_id,
      inbox_id: @contact_inbox.inbox_id,
      contact_id: @contact_inbox.contact_id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: additional_attributes,
      custom_attributes: custom_attributes,
      snoozed_until: params[:snoozed_until],
      assignee_id: params[:assignee_id],
      team_id: params[:team_id]
    }.merge(status)
  end
end
