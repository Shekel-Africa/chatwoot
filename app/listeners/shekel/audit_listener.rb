# Shekel fork: records the event-driven audit-log actions (see
# docs/shekel/AUDIT_LOG.md). Registered with AsyncDispatcher, so it runs in
# EventDispatcherJob after the request: the actor comes from the payload, never
# from Current. Messages carry their sender; conversation events carry the
# `shekel_audit` context captured at dispatch by Shekel::AuditContext, falling
# back to `performed_by`. There is no request here, so ip_address stays nil.
class Shekel::AuditListener < BaseListener
  def message_created(event)
    message, account = extract_message_and_account(event)
    return unless message.outgoing? && message.sender_type == 'User'

    Shekel::Audit.record(
      action: message.private? ? 'conversation.note_added' : 'conversation.replied',
      actor: message.sender, subject: message.conversation, account: account,
      metadata: { message_id: message.id, display_id: message.conversation.display_id }
    )
  end

  def assignee_changed(event)
    changed = changes(event)
    # Only assignee_id changes are staff assignments: this drops agent bot and AI
    # assignee changes, and the second ASSIGNEE_CHANGED that auto-assignment
    # dispatches itself (AutoAssignment::AssignmentService#dispatch_assignment_event,
    # payload without changed_attributes) for an assignment already recorded.
    return unless changed.key?('assignee_id')

    from, to = changed['assignee_id']
    record_conversation_event(event, 'conversation.assigned', from_assignee_id: from, to_assignee_id: to)
  end

  def team_changed(event)
    from, to = changes(event)['team_id']
    record_conversation_event(event, 'conversation.team_changed', from_team_id: from, to_team_id: to)
  end

  def conversation_resolved(event)
    record_conversation_event(event, 'conversation.resolved', from_status: context(event)['from_status'], to_status: 'resolved')
  end

  def conversation_opened(event)
    record_conversation_event(event, 'conversation.reopened', from_status: context(event)['from_status'], to_status: 'open')
  end

  private

  def record_conversation_event(event, action, metadata)
    conversation, account = extract_conversation_and_account(event)
    Shekel::Audit.record(action: action, actor: actor(event), subject: conversation, account: account,
                         metadata: { display_id: conversation.display_id }.merge(metadata))
  end

  def actor(event)
    captured = context(event)
    return { 'type' => captured['actor_type'], 'id' => captured['actor_id'] } if captured['actor_type'].present?

    event.data[:performed_by]
  end

  def context(event)
    event.data[:shekel_audit] || {}
  end

  def changes(event)
    (event.data[:changed_attributes] || {}).to_h.stringify_keys
  end
end
