require 'rake'
require 'rails_helper'

RSpec.describe 'shekel:configure' do # rubocop:disable RSpec/DescribeClass
  subject(:task) { Rake::Task['shekel:configure'] }

  let(:account) { create(:account) }
  let(:team) { create(:team, account: account, name: 'acme motors') }

  before do
    task.reenable
    account.update!(keep_pending_on_bot_failure: true)
    InstallationConfig.where(name: 'ENABLE_ACCOUNT_SIGNUP').first_or_create!(value: true).update!(value: true)
    Shekel::TenantTeam.create!(account: account, team: team, tenant_id: '11111111-2222-3333-4444-555555555555')
  end

  def configure
    with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: account.id.to_s) { task.invoke }
  end

  it 'turns off keep_pending_on_bot_failure and account signup, and prints the tenant teams' do
    expect { configure }.to output(/11111111-2222-3333-4444-555555555555 -> acme motors \(team #{team.id}\)/).to_stdout

    expect(account.reload.keep_pending_on_bot_failure).to be(false)
    expect(InstallationConfig.find_by(name: 'ENABLE_ACCOUNT_SIGNUP').value).to be(false)
    expect(GlobalConfigService.account_signup_enabled?).to be(false)
  end

  it 'is idempotent' do
    expect { configure }.to output.to_stdout
    task.reenable

    expect { configure }.to output(/acme motors/).to_stdout
    expect(InstallationConfig.where(name: 'ENABLE_ACCOUNT_SIGNUP').count).to eq(1)
    expect(account.reload.keep_pending_on_bot_failure).to be(false)
  end
end
