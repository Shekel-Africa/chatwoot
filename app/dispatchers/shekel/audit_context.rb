# Shekel fork: adds what Shekel::AuditListener needs to the payload of the
# conversation events it audits, captured at dispatch, inside the request.
#
# The listener runs later in EventDispatcherJob, where Current is empty, and
# these events carry only `performed_by: Current.executed_by`, which upstream
# sets for automation rules, auto-assignment and contact reopens but not for a
# signed-in user. So the actor is taken here: Current.executed_by when set,
# otherwise Current.user. It is stored as a plain type/id pair rather than a
# record, so that a deleted actor cannot make the job fail to deserialize.
# The previous status is taken here too: after commit the conversation still
# knows it (saved_change_to_status), the job no longer does.
module Shekel::AuditContext
  EVENTS = [
    Events::Types::CONVERSATION_OPENED, Events::Types::CONVERSATION_RESOLVED,
    Events::Types::ASSIGNEE_CHANGED, Events::Types::TEAM_CHANGED
  ].freeze

  def dispatch(event_name, timestamp, data, async = false) # rubocop:disable Style/OptionalBooleanParameter
    data = data.merge(shekel_audit: Shekel::AuditContext.capture(data[:conversation])) if EVENTS.include?(event_name) && !data.key?(:shekel_audit)
    super
  end

  def self.capture(conversation)
    actor = Current.executed_by || Current.user
    context = actor ? { 'actor_type' => actor.class.polymorphic_name, 'actor_id' => actor.id } : {}
    from_status = conversation.try(:saved_change_to_status)&.first
    context['from_status'] = from_status.to_s if from_status
    context
  end
end
