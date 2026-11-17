require 'rails_helper'

# Shekel fork: agents see only the contacts of their teams' conversations (Shekel::ContactVisibility).
RSpec.describe 'Shekel contact visibility', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:ng_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:ke_team) { create(:team, account: account, allow_auto_assign: false) }
  let(:ng_agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:ng_contact) { create(:contact, account: account, name: 'Ng Dealer', email: 'ng-dealer@example.com') }
  let(:ke_contact) { create(:contact, account: account, name: 'Ke Dealer', email: 'ke-dealer@example.com') }
  let!(:lonely_contact) { create(:contact, account: account, name: 'Lonely Dealer', email: 'lonely-dealer@example.com') }

  before do
    allow(Shekel::OidcSettings).to receive(:enabled?).and_return(true)
    create(:inbox_member, user: ng_agent, inbox: inbox)
    create(:team_member, team: ng_team, user: ng_agent)
    create(:conversation, account: account, inbox: inbox, team: ng_team, contact: ng_contact)
    create(:conversation, account: account, inbox: inbox, team: ke_team, contact: ke_contact)
  end

  def json
    JSON.parse(response.body, symbolize_names: true)
  end

  def path(suffix = '')
    "/api/v1/accounts/#{account.id}/contacts#{suffix}"
  end

  it 'an_agent_lists_only_the_contacts_of_their_teams_conversations' do
    get path, headers: ng_agent.create_new_auth_token, as: :json
    expect(json[:payload].pluck(:id)).to contain_exactly(ng_contact.id)
    expect(json[:meta][:count]).to eq(1)

    post path('/filter'), headers: ng_agent.create_new_auth_token, as: :json,
                          params: { payload: [{ attribute_key: 'name', filter_operator: 'contains', values: ['Dealer'], query_operator: nil }] }
    expect([json[:payload].pluck(:id), json[:meta][:count]]).to eq([[ng_contact.id], 1])
  end

  it 'contact_search_respects_visibility' do
    get path('/search'), headers: ng_agent.create_new_auth_token, params: { q: 'Dealer' }, as: :json
    expect(json[:payload].pluck(:id)).to contain_exactly(ng_contact.id)

    get "/api/v1/accounts/#{account.id}/search/contacts", headers: ng_agent.create_new_auth_token, params: { q: 'Dealer' }, as: :json
    expect(json[:payload][:contacts].pluck(:id)).to contain_exactly(ng_contact.id)
  end

  it 'an_agent_cannot_show_update_or_read_another_countrys_contact_by_id' do
    [[:get, path("/#{ke_contact.id}")], [:patch, path("/#{ke_contact.id}")], [:get, path("/#{ke_contact.id}/conversations")],
     [:get, path("/#{ke_contact.id}/notes")], [:get, path("/#{lonely_contact.id}")]].each do |verb, url|
      public_send(verb, url, headers: ng_agent.create_new_auth_token, params: { name: 'Hijacked' }, as: :json)
      expect(response).to have_http_status(:not_found), "#{verb} #{url} returned #{response.status}"
      expect(response.body).not_to include('Ke Dealer', 'ke-dealer@example.com')
    end
    expect(ke_contact.reload.name).to eq('Ke Dealer')

    get path("/#{ng_contact.id}"), headers: ng_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
  end

  it 'an_agent_cannot_start_a_conversation_with_a_contact_they_cannot_see' do
    expect do
      post "/api/v1/accounts/#{account.id}/conversations", headers: ng_agent.create_new_auth_token, as: :json,
                                                           params: { inbox_id: inbox.id, contact_id: ke_contact.id }
    end.not_to change(Conversation, :count)
    expect(response).to have_http_status(:not_found)

    source_id = ke_contact.contact_inboxes.first.source_id
    post "/api/v1/accounts/#{account.id}/conversations", headers: ng_agent.create_new_auth_token, as: :json,
                                                         params: { source_id: source_id }
    expect(response).to have_http_status(:not_found)
  end

  it 'an_administrator_sees_every_contact' do
    get path, headers: admin.create_new_auth_token, as: :json

    expect(json[:payload].pluck(:id)).to contain_exactly(ng_contact.id, ke_contact.id, lonely_contact.id)
  end

  it 'an_agent_created_conversation_stays_visible_to_its_creator' do
    post "/api/v1/accounts/#{account.id}/conversations", headers: ng_agent.create_new_auth_token, as: :json,
                                                         params: { inbox_id: inbox.id, contact_id: ng_contact.id }
    expect(response).to have_http_status(:success)
    expect(Conversation.find_by(display_id: json[:id]).team_id).to eq(ng_team.id)

    create(:team_member, team: ke_team, user: ng_agent)
    post "/api/v1/accounts/#{account.id}/conversations", headers: ng_agent.create_new_auth_token, as: :json,
                                                         params: { inbox_id: inbox.id, contact_id: ng_contact.id }
    conversation = Conversation.find_by(display_id: json[:id])
    expect([conversation.team_id, conversation.assignee_id]).to eq([nil, ng_agent.id])

    get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: ng_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:success)
  end

  it 'unread_counts_respect_visibility' do
    account.enable_features!(:conversation_unread_counts)
    Conversation.find_each { |conversation| create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming) }

    get "/api/v1/accounts/#{account.id}/conversations/unread_counts", headers: ng_agent.create_new_auth_token, as: :json

    expect(json[:payload]).to include(all_count: 1, inboxes: { inbox.id.to_s.to_sym => 1 }, teams: { ng_team.id.to_s.to_sym => 1 })
  end
end
