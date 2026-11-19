# Shekel fork: the `shekel_*` contact custom attributes belong to the Shailoq
# gateway (dealer link, tenant and so on). Creating, changing or deleting one is
# refused (422 in the API) unless the save is made by
#
# - a User listed in SHEKEL_API_USER_IDS (Shekel::ApiTokens): the gateway's
#   service user, signed in with its personal access token; or
# - code inside Shekel::TrustedWriter.with.
#
# Deny by default: staff, agent bots (Current.user is an AgentBot; a bot is
# never the service user even if its id equals a listed user id), the website
# widget, the Public API, imports, background jobs and the Rails console are all
# refused. Enforced on the model so every path that saves a contact is covered
# (create, update, destroy_custom_attributes, contact merge and identify).
# A save that sends an unchanged `shekel_*` value back is accepted, so a
# dashboard edit that echoes the whole attribute hash still works.
module Shekel::LockedContactAttributes
  extend ActiveSupport::Concern

  LOCKED_PREFIX = 'shekel_'.freeze

  included do
    validate :shekel_attributes_unchanged_by_untrusted_writer, if: :will_save_change_to_custom_attributes?
  end

  private

  def shekel_attributes_unchanged_by_untrusted_writer
    return if shekel_trusted_writer?
    return if locked_custom_attributes(custom_attributes_was) == locked_custom_attributes(custom_attributes)

    errors.add(:custom_attributes, I18n.t('errors.contacts.shekel_attributes_locked'))
  end

  def shekel_trusted_writer?
    return true if Shekel::TrustedWriter.active?

    actor = Current.user
    actor.is_a?(User) && Shekel::ApiTokens.allowed_user_id?(actor.id)
  end

  def locked_custom_attributes(attributes)
    (attributes || {}).select { |key, _value| key.to_s.start_with?(LOCKED_PREFIX) }
  end
end
