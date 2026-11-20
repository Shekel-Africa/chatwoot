# Shekel fork: marks a block of code we own as allowed to write the shekel_*
# contact custom attributes (Shekel::LockedContactAttributes). Everything else
# is refused, including the website widget, the Public API, imports, background
# jobs and the Rails console.
#
# Nothing in this app needs it today: the Shailoq gateway writes the keys over
# the API with the service user's token (SHEKEL_API_USER_IDS). Use it from the
# console for a one-off repair or backfill, or from a new job that must own the
# keys, never around code that handles visitor, staff or file input:
#
#   Shekel::TrustedWriter.with { contact.update!(custom_attributes: { 'shekel_dealer_id' => id }) }
module Shekel::TrustedWriter
  module_function

  def with
    previous = Current.shekel_trusted_writer
    Current.shekel_trusted_writer = true
    yield
  ensure
    Current.shekel_trusted_writer = previous
  end

  def active?
    Current.shekel_trusted_writer == true
  end
end
