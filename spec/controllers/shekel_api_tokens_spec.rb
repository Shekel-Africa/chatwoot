require 'rails_helper'

# Shekel fork: in staff mode, personal (User) API access tokens would bypass
# the 12-hour session, IdP revocation and the team re-sync, so they are refused
# unless the user is allow-listed in SHEKEL_API_USER_IDS. Agent bot tokens are
# unaffected. See Shekel::ApiTokens.
RSpec.describe 'Shekel personal API tokens', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:service_user) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:staff_mode) { { SHEKEL_CHATWOOT_ACCOUNT_ID: account.id.to_s, SHEKEL_API_USER_IDS: nil } }

  it 'refuses an agent user token in staff mode' do
    with_modified_env(**staff_mode) do
      get '/api/v1/profile', headers: { api_access_token: agent.access_token.token }, as: :json
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/accounts/#{account.id}/conversations", headers: { api_access_token: agent.access_token.token }, as: :json
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/accounts/#{account.id}/conversations", headers: { Authorization: "Bearer #{agent.access_token.token}" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'still accepts an agent bot token in staff mode' do
    agent_bot = create(:agent_bot, account: account)
    create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)

    with_modified_env(**staff_mode) do
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
           headers: { api_access_token: agent_bot.access_token.token }, params: { status: 'resolved' }, as: :json

      expect(response).to have_http_status(:success)
      expect(conversation.reload.status).to eq('resolved')
    end
  end

  it 'accepts the token of a user listed in SHEKEL_API_USER_IDS' do
    with_modified_env(**staff_mode, SHEKEL_API_USER_IDS: " 0, #{service_user.id} ") do
      get "/api/v1/accounts/#{account.id}/contacts", headers: { api_access_token: service_user.access_token.token }, as: :json
      expect(response).to have_http_status(:success)

      get "/api/v1/accounts/#{account.id}/contacts", headers: { api_access_token: agent.access_token.token }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'leaves user tokens as upstream when staff mode is off' do
    with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil) do
      get '/api/v1/profile', headers: { api_access_token: agent.access_token.token }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['access_token']).to eq(agent.access_token.token)
    end
  end

  it 'does not put the access token in the user JSON in staff mode' do
    with_modified_env(**staff_mode) do
      get '/api/v1/profile', headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['access_token']).to eq('')

      post '/api/v1/profile/reset_access_token', headers: agent.create_new_auth_token, as: :json
      expect(response.parsed_body['access_token']).to eq('')
    end
  end

  it 'shows the token to an allow-listed user' do
    with_modified_env(**staff_mode, SHEKEL_API_USER_IDS: service_user.id.to_s) do
      get '/api/v1/profile', headers: service_user.create_new_auth_token, as: :json

      expect(response.parsed_body['access_token']).to eq(service_user.access_token.token)
    end
  end
end
