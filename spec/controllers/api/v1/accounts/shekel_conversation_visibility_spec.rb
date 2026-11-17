require 'rails_helper'

# Shekel fork: agents see only their teams' conversations (Shekel::ConversationVisibility).
RSpec.describe 'Shekel conversation visibility', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:ng_team) { create(:team, account: account, name: 'nigeria', allow_auto_assign: false) }
  let(:ke_team) { create(:team, account: account, name: 'kenya', allow_auto_assign: false) }
  let(:ng_agent) { create(:user, account: account, role: :agent) }
  let(:ke_agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let!(:ng_conversation) { create(:conversation, account: account, inbox: inbox, team: ng_team) }
  let!(:ke_conversation) { create(:conversation, account: account, inbox: inbox, team: ke_team) }
  let!(:unteamed_conversation) { create(:conversation, account: account, inbox: inbox, team: nil) }

  before do
    allow(Shekel::OidcSettings).to receive(:staff_mode?).and_return(true)
    [ng_agent, ke_agent].each { |agent| create(:inbox_member, user: agent, inbox: inbox) }
    create(:team_member, team: ng_team, user: ng_agent)
    create(:team_member, team: ke_team, user: ke_agent)
    create(:message, conversation: ng_conversation, account: account, inbox: inbox, content: 'ng-secret hello')
    create(:message, conversation: ke_conversation, account: account, inbox: inbox, content: 'ke-secret hello')
    create(:message, conversation: unteamed_conversation, account: account, inbox: inbox, content: 'unteamed-secret hello')
  end

  def json
    JSON.parse(response.body, symbolize_names: true)
  end

  def listed_ids(user, params = {})
    get "/api/v1/accounts/#{account.id}/conversations", headers: user.create_new_auth_token, params: params.merge(status: 'all'), as: :json
    expect(response).to have_http_status(:success)
    json[:data][:payload].pluck(:id)
  end

  def visible_by_id?(user, conversation)
    get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: user.create_new_auth_token, as: :json
    response.successful?
  end

  it 'an_agent_lists_only_their_teams_conversations' do
    expect(listed_ids(ng_agent)).to contain_exactly(ng_conversation.display_id)
    expect(listed_ids(ke_agent)).to contain_exactly(ke_conversation.display_id)
    expect(listed_ids(ng_agent, team_id: ke_team.id)).to be_empty
    expect(listed_ids(ng_agent, inbox_id: inbox.id)).to contain_exactly(ng_conversation.display_id)
  end

  it 'an_agent_sees_a_conversation_assigned_to_them_in_another_team' do
    ke_conversation.update!(assignee: ng_agent)

    expect(listed_ids(ng_agent)).to contain_exactly(ng_conversation.display_id, ke_conversation.display_id)
    expect(visible_by_id?(ng_agent, ke_conversation)).to be(true)
  end

  it 'an_agent_cannot_show_or_read_messages_of_another_country_by_id' do
    base = "/api/v1/accounts/#{account.id}/conversations/#{ke_conversation.display_id}"
    requests = [
      [:get, base], [:get, "#{base}/messages"], [:get, "#{base}/attachments"], [:post, "#{base}/transcript"],
      [:get, "#{base}/participants"], [:get, "#{base}/labels"], [:get, "#{base}/draft_messages"],
      [:post, "#{base}/messages"], [:post, "#{base}/assignments"], [:post, "#{base}/toggle_status"],
      [:post, "#{base}/update_last_seen"], [:post, "#{base}/custom_attributes"]
    ]

    requests.each do |verb, path|
      public_send(verb, path, headers: ng_agent.create_new_auth_token, params: { content: 'x' }, as: :json)
      expect(response).to have_http_status(:not_found), "#{verb} #{path} returned #{response.status}"
      expect(response.body).not_to include('ke-secret')
    end
    expect(ke_conversation.messages.where(content: 'x')).to be_empty
    expect(visible_by_id?(ng_agent, ng_conversation)).to be(true)
  end

  it 'an_agent_who_left_a_team_loses_its_conversations' do
    expect(visible_by_id?(ng_agent, ng_conversation)).to be(true)

    ng_team.remove_members([ng_agent.id])

    expect(listed_ids(ng_agent)).to be_empty
    expect(visible_by_id?(ng_agent, ng_conversation)).to be(false)
  end

  it 'search_and_filter_endpoints_respect_visibility' do
    get "/api/v1/accounts/#{account.id}/conversations/search", headers: ng_agent.create_new_auth_token, params: { q: 'secret' }, as: :json
    expect([json[:payload].pluck(:id), json[:meta][:all_count]]).to eq([[ng_conversation.display_id], 1])

    post "/api/v1/accounts/#{account.id}/conversations/filter", headers: ng_agent.create_new_auth_token, as: :json,
                                                                params: { payload: [{ attribute_key: 'status', filter_operator: 'equal_to',
                                                                                      values: ['open'], query_operator: nil }] }
    expect([json[:payload].pluck(:id), json[:meta][:all_count]]).to eq([[ng_conversation.display_id], 1])

    get "/api/v1/accounts/#{account.id}/search/conversations", headers: ng_agent.create_new_auth_token, params: { q: '' }, as: :json
    expect(json[:payload][:conversations].pluck(:id)).to contain_exactly(ng_conversation.display_id)

    get "/api/v1/accounts/#{account.id}/search/messages", headers: ng_agent.create_new_auth_token, params: { q: 'secret' }, as: :json
    expect(response.body).to include('ng-secret')
    expect(response.body).not_to include('ke-secret', 'unteamed-secret')

    get "/api/v1/accounts/#{account.id}/search", headers: ng_agent.create_new_auth_token, params: { q: 'secret' }, as: :json
    expect(response.body).not_to include('ke-secret', 'unteamed-secret')
  end

  it 'meta_counts_respect_visibility' do
    ng_conversation.update!(assignee: ng_agent)

    get "/api/v1/accounts/#{account.id}/conversations/meta", headers: ng_agent.create_new_auth_token, params: { status: 'all' }, as: :json

    expect(json[:meta]).to include(all_count: 1, mine_count: 1, unassigned_count: 0, assigned_count: 1)
  end

  it 'an_administrator_sees_everything' do
    expect(listed_ids(admin)).to contain_exactly(ng_conversation.display_id, ke_conversation.display_id, unteamed_conversation.display_id)
    expect(visible_by_id?(admin, ke_conversation)).to be(true)
    expect(visible_by_id?(admin, unteamed_conversation)).to be(true)
  end

  it 'an_unteamed_conversation_is_visible_only_to_administrators_and_the_assignee' do
    expect(listed_ids(ng_agent)).not_to include(unteamed_conversation.display_id)
    expect(visible_by_id?(ng_agent, unteamed_conversation)).to be(false)

    unteamed_conversation.update!(assignee: ke_agent)

    expect(listed_ids(ke_agent)).to include(unteamed_conversation.display_id)
    expect(visible_by_id?(ke_agent, unteamed_conversation)).to be(true)
    expect(visible_by_id?(ng_agent, unteamed_conversation)).to be(false)
  end

  # Fails closed: staff mode keys on SHEKEL_CHATWOOT_ACCOUNT_ID, so losing the
  # OIDC settings does not open every conversation to every agent.
  it 'still restricts agents when staff mode is on and Shekel sign-in is not configured' do
    allow(Shekel::OidcSettings).to receive(:enabled?).and_return(false)

    expect(listed_ids(ng_agent)).to contain_exactly(ng_conversation.display_id)
    expect(visible_by_id?(ng_agent, ke_conversation)).to be(false)
  end

  it 'leaves upstream inbox access alone when staff mode is off' do
    allow(Shekel::OidcSettings).to receive(:staff_mode?).and_return(false)

    expect(listed_ids(ng_agent)).to contain_exactly(ng_conversation.display_id, ke_conversation.display_id, unteamed_conversation.display_id)
    expect(visible_by_id?(ng_agent, ke_conversation)).to be(true)
  end
end
