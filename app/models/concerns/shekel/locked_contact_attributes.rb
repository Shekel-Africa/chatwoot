# Shekel fork: the `shekel_*` contact custom attributes belong to the Shailoq
# gateway (dealer link, tenant and so on). A request made by anyone other than
# a service user listed in SHEKEL_API_USER_IDS (Shekel::ApiTokens) must leave
# them as they are: creating, changing or deleting one is refused with 422.
#
# Enforced on the model so every dashboard API path that saves a contact is
# covered (create, update, destroy_custom_attributes, contact merge). A save
# with no signed-in actor (jobs, the Rails console, the Platform API) is not
# affected, and a dashboard edit that sends an unchanged `shekel_*` value back
# is accepted.
module Shekel::LockedContactAttributes
  extend ActiveSupport::Concern

  LOCKED_PREFIX = 'shekel_'.freeze

  included do
    validate :shekel_attributes_unchanged_by_staff, if: :will_save_change_to_custom_attributes?
  end

  private

  def shekel_attributes_unchanged_by_staff
    return unless shekel_attributes_locked_for_current_actor?
    return if locked_custom_attributes(custom_attributes_was) == locked_custom_attributes(custom_attributes)

    errors.add(:custom_attributes, I18n.t('errors.contacts.shekel_attributes_locked'))
  end

  def shekel_attributes_locked_for_current_actor?
    actor = Current.user
    return false if actor.blank?

    !(actor.is_a?(User) && Shekel::ApiTokens.allowed_user_id?(actor.id))
  end

  def locked_custom_attributes(attributes)
    (attributes || {}).select { |key, _value| key.to_s.start_with?(LOCKED_PREFIX) }
  end
end
