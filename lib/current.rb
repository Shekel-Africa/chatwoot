module Current
  thread_mattr_accessor :user
  thread_mattr_accessor :account
  thread_mattr_accessor :account_user
  thread_mattr_accessor :executed_by
  thread_mattr_accessor :contact
  thread_mattr_accessor :inbox
  # Shekel fork: per-request memo for Shekel::ConversationVisibility.
  thread_mattr_accessor :shekel_visibility
  # Shekel fork: set by Shekel::TrustedWriter.with to let code we own write shekel_* contact attributes.
  thread_mattr_accessor :shekel_trusted_writer

  def self.reset
    Current.user = nil
    Current.account = nil
    Current.account_user = nil
    Current.executed_by = nil
    Current.contact = nil
    Current.inbox = nil
    Current.shekel_visibility = nil # Shekel fork
    Current.shekel_trusted_writer = nil # Shekel fork
  end
end
