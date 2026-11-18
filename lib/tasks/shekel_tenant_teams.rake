# Shekel fork: map authentication-api tenants to Chatwoot teams in the account
# set by SHEKEL_CHATWOOT_ACCOUNT_ID. Staff join the mapped team on their next
# Shekel sign-in (Shekel::StaffSync).
#
#   bundle exec rails "shekel:map_tenant_team[<tenant uuid>,Acme Motors]"
#   bundle exec rails shekel:list_tenant_teams
namespace :shekel do
  desc 'Map a Shekel tenant to a team, creating the team if it is missing'
  task :map_tenant_team, [:tenant_id, :team_name] => :environment do |_task, args|
    abort 'Usage: rails "shekel:map_tenant_team[tenant_id,team_name]"' if args[:tenant_id].blank? || args[:team_name].blank?

    account = Account.find(Shekel::OidcSettings.account_id)
    team = account.teams.find_or_create_by!(name: args[:team_name].strip.downcase)
    mapping = Shekel::TenantTeam.find_or_initialize_by(account: account, tenant_id: args[:tenant_id].strip.downcase)
    mapping.update!(team: team)

    puts "#{mapping.tenant_id} -> #{team.name} (team #{team.id})"
  end

  desc 'List the Shekel tenant to team mappings'
  task list_tenant_teams: :environment do
    account = Account.find(Shekel::OidcSettings.account_id)
    Shekel::TenantTeam.where(account: account).includes(:team).order(:tenant_id).each do |mapping|
      puts "#{mapping.tenant_id} -> #{mapping.team.name} (team #{mapping.team_id})"
    end
  end
end
