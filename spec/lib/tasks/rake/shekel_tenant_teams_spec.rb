require 'rake'
require 'rails_helper'

RSpec.describe 'shekel tenant team tasks' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:tenant_id) { '11111111-2222-3333-4444-555555555555' }

  def run_task(name, *)
    task = Rake::Task[name]
    task.reenable
    with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: account.id.to_s) { task.invoke(*) }
  end

  describe 'shekel:map_tenant_team' do
    it 'creates the team and the mapping, and is idempotent' do
      expect { run_task('shekel:map_tenant_team', tenant_id.upcase, ' Acme Motors ') }.to output(/#{tenant_id} -> acme motors/).to_stdout
      expect { run_task('shekel:map_tenant_team', tenant_id, 'Acme Motors') }.to output.to_stdout

      expect(account.teams.where(name: 'acme motors').count).to eq(1)
      expect(Shekel::TenantTeam.where(account: account, tenant_id: tenant_id).count).to eq(1)
    end

    it 'repoints a tenant to another team' do
      expect { run_task('shekel:map_tenant_team', tenant_id, 'Acme Motors') }.to output.to_stdout
      expect { run_task('shekel:map_tenant_team', tenant_id, 'Beta Cars') }.to output.to_stdout

      expect(Shekel::TenantTeam.find_by!(account: account, tenant_id: tenant_id).team.name).to eq('beta cars')
    end

    it 'aborts without a tenant id or team name' do
      expect { expect { run_task('shekel:map_tenant_team', tenant_id, '') }.to raise_error(SystemExit) }.to output(/Usage/).to_stderr
    end
  end

  describe 'shekel:list_tenant_teams' do
    it 'lists the mappings of the account' do
      team = create(:team, account: account, name: 'acme motors')
      Shekel::TenantTeam.create!(account: account, team: team, tenant_id: tenant_id)

      expect { run_task('shekel:list_tenant_teams') }.to output(/#{tenant_id} -> acme motors \(team #{team.id}\)/).to_stdout
    end
  end
end
