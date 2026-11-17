# Shekel fork: configure the account set by SHEKEL_CHATWOOT_ACCOUNT_ID for
# Shekel staff. Safe to run on every deploy. Prints no secrets.
#
#   bundle exec rails shekel:configure
#
# - keep_pending_on_bot_failure off: a conversation goes to the team when the
#   Shailoq bot fails, instead of waiting in pending;
# - account sign-up off (ENABLE_ACCOUNT_SIGNUP, an installation config): staff
#   are provisioned by Shekel sign-in only;
# - prints the tenant-team mapping (see shekel:map_tenant_team).
namespace :shekel do
  desc 'Configure the Shekel staff account (idempotent)'
  task configure: :environment do
    account = Account.find(Shekel::OidcSettings.account_id)

    account.update!(keep_pending_on_bot_failure: false)
    puts "Account #{account.id}: keep_pending_on_bot_failure = false"

    signup = InstallationConfig.where(name: 'ENABLE_ACCOUNT_SIGNUP').first_or_create!(value: false, locked: false)
    signup.update!(value: false)
    puts 'ENABLE_ACCOUNT_SIGNUP = false'

    mappings = Shekel::TenantTeam.where(account: account).includes(:team).order(:tenant_id)
    puts "Tenant teams (#{mappings.size}):"
    mappings.each { |mapping| puts "  #{mapping.tenant_id} -> #{mapping.team.name} (team #{mapping.team_id})" }
  end
end
