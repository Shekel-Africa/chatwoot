# Shekel fork: maps an authentication-api tenant (by uuid) to a Chatwoot team.
# Staff who hold the tenant join the team on sign-in; see Shekel::StaffSync.
class Shekel::TenantTeam < ApplicationRecord
  self.table_name = 'shekel_tenant_teams'

  belongs_to :account
  belongs_to :team

  before_validation { self.tenant_id = tenant_id.to_s.strip.downcase.presence }

  validates :tenant_id, presence: true, uniqueness: { scope: :account_id }
  validate :team_belongs_to_account

  def self.team_ids_for(account, tenant_ids)
    where(account: account, tenant_id: Array(tenant_ids).map { |id| id.to_s.downcase }).pluck(:team_id)
  end

  private

  def team_belongs_to_account
    errors.add(:team, 'must belong to the same account') if team && team.account_id != account_id
  end
end
