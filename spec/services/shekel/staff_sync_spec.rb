require 'rails_helper'

RSpec.describe Shekel::StaffSync do
  let(:account) { create(:account) }
  let(:email) { 'ada@shekel.test' }
  let(:tenant_a) { '0b4f3c1e-8a1d-4d5c-9a51-0d1c5a3b7e01' }
  let(:tenant_b) { '0b4f3c1e-8a1d-4d5c-9a51-0d1c5a3b7e02' }

  def sync(tenant_ids: [], admin: false)
    described_class.new(account: account, email: email, name: 'Ada Admin', tenant_ids: tenant_ids, admin: admin).call
  end

  def map_tenant(tenant_id, team)
    Shekel::TenantTeam.create!(account: account, tenant_id: tenant_id, team: team)
  end

  def role_of(user)
    account.account_users.find_by!(user: user).role
  end

  it 'creates_an_agent_on_first_sign_in' do
    user = nil
    expect { user = sync }.to change(User, :count).by(1)

    expect(user.email).to eq(email)
    expect(user.name).to eq('Ada Admin')
    expect(user).to be_confirmed
    expect(role_of(user)).to eq('agent')
  end

  it 'rotates_the_personal_api_token_on_every_sign_in' do
    user = sync
    token = user.access_token.reload.token

    sync
    expect(user.access_token.reload.token).not_to eq(token)
  end

  it 'keeps_the_api_token_of_an_allow_listed_service_user' do
    user = sync
    token = user.access_token.reload.token

    with_modified_env(SHEKEL_API_USER_IDS: user.id.to_s) { sync }
    expect(user.access_token.reload.token).to eq(token)
  end

  it 'promotes_to_administrator_when_crm_admin_is_granted_and_demotes_when_it_is_not' do
    user = sync(admin: true)
    expect(role_of(user)).to eq('administrator')

    sync(admin: false)
    expect(role_of(user)).to eq('agent')
  end

  it 'joins_mapped_teams_for_held_tenants' do
    team_a = create(:team, account: account)
    team_b = create(:team, account: account)
    map_tenant(tenant_a, team_a)
    map_tenant(tenant_b, team_b)

    user = sync(tenant_ids: [tenant_a])

    expect(team_a.members).to include(user)
    expect(team_b.members).not_to include(user)
  end

  it 'leaves_a_mapped_team_when_its_tenant_is_removed' do
    team_a = create(:team, account: account)
    team_b = create(:team, account: account)
    map_tenant(tenant_a, team_a)
    map_tenant(tenant_b, team_b)

    user = sync(tenant_ids: [tenant_a, tenant_b])
    expect(team_b.members).to include(user)

    sync(tenant_ids: [tenant_a])

    expect(team_a.reload.members).to include(user)
    expect(team_b.reload.members).not_to include(user)
  end

  it 'leaves_unmapped_teams_alone' do
    unmapped = create(:team, account: account)
    user = sync
    unmapped.add_members([user.id])

    sync(tenant_ids: [])

    expect(unmapped.reload.members).to include(user)
  end

  it 'missing_tenants_claim_leaves_teams_unchanged' do
    team = create(:team, account: account)
    map_tenant(tenant_a, team)
    user = sync(tenant_ids: [tenant_a])

    sync(tenant_ids: nil, admin: true)

    expect(team.reload.members).to include(user)
    expect(role_of(user)).to eq('administrator')
  end

  it 'adds_the_user_to_every_inbox' do
    inboxes = create_list(:inbox, 2, account: account)
    other_account_inbox = create(:inbox)

    user = sync

    inboxes.each { |inbox| expect(inbox.members).to include(user) }
    expect(other_account_inbox.members).not_to include(user)
  end

  it 'is_idempotent' do
    team = create(:team, account: account)
    map_tenant(tenant_a, team)
    inbox = create(:inbox, account: account)

    user = sync(tenant_ids: [tenant_a], admin: true)

    expect do
      expect(sync(tenant_ids: [tenant_a], admin: true)).to eq(user)
    end.not_to(change { [User.count, AccountUser.count, TeamMember.count, InboxMember.count] })

    expect(team.members).to contain_exactly(user)
    expect(inbox.members).to contain_exactly(user)
    expect(role_of(user)).to eq('administrator')
  end

  it 'retries once when a concurrent first sign-in wins the insert' do
    calls = 0
    allow(User).to receive(:from_email).and_wrap_original do |original, *args|
      calls += 1
      raise ActiveRecord::RecordNotUnique, 'duplicate key value' if calls == 1

      original.call(*args)
    end

    user = sync

    expect(user).to be_persisted
    expect(calls).to eq(2)
  end

  it 'matches an existing user by email case-insensitively and keeps their password' do
    existing = create(:user, email: email)
    encrypted_password = existing.encrypted_password

    user = described_class.new(account: account, email: 'Ada@Shekel.TEST', name: 'Ada Admin', tenant_ids: [], admin: false).call

    expect(user).to eq(existing)
    expect(user.reload.encrypted_password).to eq(encrypted_password)
  end
end
