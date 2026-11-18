# Shekel fork: provisions and syncs a staff member on each Shekel sign-in.
#
# - Finds the user by the IdP subject (`sub`, kept in custom_attributes as
#   `shekel_sub`), then by email, so an email change at the IdP keeps the same
#   Chatwoot user and the Chatwoot email follows it. A user who already exists
#   with the same email (created by hand, or before Shekel sign-in) is adopted
#   on their first Shekel sign-in.
# - Creates the user (random password, confirmed) the first time.
# - Sets their role in the account: administrator with the CRM admin grant,
#   agent without it.
# - Puts them in the teams mapped (Shekel::TenantTeam) from the tenants they
#   hold and takes them out of mapped teams for tenants they no longer hold.
#   Teams with no mapping are left alone. `tenant_ids: nil` means the tenants
#   are unknown (no claim), so team membership is not touched at all.
# - Adds them to every inbox of the account.
# - Rotates their personal API token, which is refused in staff mode anyway
#   (Shekel::ApiTokens), unless they are an allow-listed service user.
#
# Safe to run on every sign-in. Two concurrent first sign-ins for the same
# person race on the inserts; the loser retries once and finds the winner's rows.
class Shekel::StaffSync
  SUB_ATTRIBUTE = 'shekel_sub'.freeze

  # `identity` is the IdP's `{ sub:, email:, name: }`.
  def initialize(account:, identity:, tenant_ids:, admin:)
    @account = account
    @sub = identity[:sub].to_s.presence
    @email = identity[:email].to_s.strip.downcase
    @name = identity[:name].presence || @email.split('@').first
    @tenant_ids = tenant_ids&.map { |id| id.to_s.downcase }
    @admin = admin
  end

  def call
    attempts = 0
    begin
      attempts += 1
      sync
    rescue ActiveRecord::RecordNotUnique
      raise if attempts > 1

      retry
    end
  end

  private

  # A savepoint, so a unique violation rolls back only this attempt even when
  # the caller already holds a transaction.
  def sync
    ActiveRecord::Base.transaction(requires_new: true) do
      user = find_or_create_user
      sync_role(user)
      sync_teams(user) unless @tenant_ids.nil?
      sync_inboxes(user)
      rotate_api_token(user)
      user
    end
  end

  def find_or_create_user
    user = user_by_sub || User.from_email(@email)
    return create_user if user.nil?

    adopt(user)
    user
  end

  def user_by_sub
    return if @sub.nil?

    User.where("custom_attributes ->> '#{SUB_ATTRIBUTE}' = ?", @sub).order(:id).first
  end

  # Links the user to the IdP subject, follows an email change at the IdP and
  # confirms them (the IdP verified the email; upstream's OAuth sign-in confirms
  # the same way).
  def adopt(user)
    user.skip_confirmation! unless user.confirmed?
    link_sub(user)
    follow_email(user)
    user.save! if user.changed?
  end

  def link_sub(user)
    return if @sub.nil? || user.custom_attributes[SUB_ATTRIBUTE] == @sub

    previous = user.custom_attributes[SUB_ATTRIBUTE]
    Rails.logger.warn("Shekel staff sync: user #{user.id} was linked to another IdP subject; relinking") if previous.present?
    user.custom_attributes = user.custom_attributes.merge(SUB_ATTRIBUTE => @sub)
  end

  def follow_email(user)
    return if user.email.casecmp?(@email)

    if User.from_email(@email)
      Rails.logger.warn("Shekel staff sync: user #{user.id} changed email at the IdP to one another user holds; email not updated")
      return
    end

    user.skip_reconfirmation!
    user.email = @email
  end

  def create_user
    password = "1!aA#{SecureRandom.alphanumeric(16)}"
    custom_attributes = @sub ? { SUB_ATTRIBUTE => @sub } : {}
    User.new(email: @email, name: @name, password: password, password_confirmation: password, custom_attributes: custom_attributes).tap do |user|
      user.skip_confirmation!
      user.save!
    end
  end

  def sync_role(user)
    account_user = @account.account_users.find_or_initialize_by(user: user)
    account_user.role = @admin ? :administrator : :agent
    account_user.save! if account_user.new_record? || account_user.changed?
  end

  def sync_teams(user)
    held = Shekel::TenantTeam.team_ids_for(@account, @tenant_ids)
    mapped = Shekel::TenantTeam.where(account: @account).distinct.pluck(:team_id)
    member_of = TeamMember.where(user: user, team_id: mapped).pluck(:team_id)

    @account.teams.where(id: held - member_of).find_each { |team| team.add_members([user.id]) }
    @account.teams.where(id: member_of - held).find_each { |team| team.remove_members([user.id]) }
  end

  def rotate_api_token(user)
    return if Shekel::ApiTokens.allowed_user_id?(user.id)

    user.access_token&.regenerate_token
  end

  def sync_inboxes(user)
    member_of = InboxMember.where(user: user).select(:inbox_id)
    @account.inboxes.where.not(id: member_of).find_each { |inbox| inbox.add_members([user.id]) }
  end
end
