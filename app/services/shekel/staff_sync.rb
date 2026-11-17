# Shekel fork: provisions and syncs a staff member on each Shekel sign-in.
#
# - Creates the user (random password, confirmed) the first time.
# - Sets their role in the account: administrator with the CRM admin grant,
#   agent without it.
# - Puts them in the teams mapped (Shekel::TenantTeam) from the tenants they
#   hold and takes them out of mapped teams for tenants they no longer hold.
#   Teams with no mapping are left alone. `tenant_ids: nil` means the tenants
#   are unknown (no claim), so team membership is not touched at all.
# - Adds them to every inbox of the account.
#
# Safe to run on every sign-in.
class Shekel::StaffSync
  def initialize(account:, email:, name:, tenant_ids:, admin:)
    @account = account
    @email = email.to_s.strip.downcase
    @name = name.presence || @email.split('@').first
    @tenant_ids = tenant_ids&.map { |id| id.to_s.downcase }
    @admin = admin
  end

  def call
    ActiveRecord::Base.transaction do
      user = find_or_create_user
      sync_role(user)
      sync_teams(user) unless @tenant_ids.nil?
      sync_inboxes(user)
      user
    end
  end

  private

  def find_or_create_user
    User.from_email(@email) || create_user
  end

  def create_user
    password = "1!aA#{SecureRandom.alphanumeric(16)}"
    User.new(email: @email, name: @name, password: password, password_confirmation: password).tap do |user|
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

  def sync_inboxes(user)
    member_of = InboxMember.where(user: user).select(:inbox_id)
    @account.inboxes.where.not(id: member_of).find_each { |inbox| inbox.add_members([user.id]) }
  end
end
