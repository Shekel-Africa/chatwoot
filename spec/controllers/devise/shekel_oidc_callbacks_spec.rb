require 'rails_helper'

# Shekel fork: staff sign-in through authentication-api's admin realm.
RSpec.describe 'Shekel OIDC staff sign-in', type: :request do
  let(:frontend_url) { 'http://www.example.com' }
  let(:shekel_env) do
    {
      FRONTEND_URL: frontend_url,
      SHEKEL_OIDC_ISSUER: 'https://auth.example.test/oauth/admin',
      SHEKEL_OIDC_CLIENT_ID: 'chatwoot-test-client',
      SHEKEL_OIDC_CLIENT_SECRET: 'test-secret',
      SHEKEL_OIDC_REDIRECT_URI: "#{frontend_url}/omniauth/shekel/callback",
      SHEKEL_OIDC_AUTHORIZE_URL: 'https://auth.example.test/oauth/admin/authorize',
      SHEKEL_OIDC_TOKEN_URL: 'https://auth.example.test/oauth/admin/token',
      SHEKEL_OIDC_USERINFO_URL: 'https://auth.example.test/oauth/admin/userinfo',
      SHEKEL_OIDC_JWKS_URL: 'https://auth.example.test/oauth/jwks',
      SHEKEL_OIDC_DISCOVERY: nil,
      SHEKEL_CHATWOOT_ACCOUNT_ID: account.id.to_s
    }
  end
  let(:account) { create(:account) }
  let(:tenant_id) { '6f1c2a9e-3b7d-4e8f-9a0b-1c2d3e4f5a6b' }
  let(:access_scope) { 'openid email profile tenants customer_comms.access' }
  let(:admin_scope) { "#{access_scope} customer_comms.admin" }

  def tenant_claim(id)
    { id: id, slug: 'acme-motors', country: 'ng' }
  end

  def mock_shekel_auth(email:, realm: 'admin', tenants: [], scope: nil)
    raw_info = { sub: '42', email: email, name: 'Ada Admin', realm: realm, tenants: tenants }.compact
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:shekel] = OmniAuth::AuthHash.new(
      provider: 'shekel',
      uid: '42',
      info: { name: 'Ada Admin', email: email },
      credentials: { token: 'access-token', scope: scope || access_scope },
      extra: { raw_info: raw_info }
    )
  end

  def redirect_query
    Rack::Utils.parse_query(URI.parse(response.location).query)
  end

  def expect_refused_at_first_hop
    get '/omniauth/shekel/callback'
    expect(response).to redirect_to("#{frontend_url}/app/login?error=no-account-found")
  end

  def complete_callback
    get '/omniauth/shekel/callback'
    expect(response).to redirect_to("#{frontend_url}/auth/shekel/callback")
    follow_redirect!
  end

  after do
    OmniAuth.config.mock_auth.delete(:shekel)
  end

  describe 'callback' do
    let!(:agent) { create(:user, email: 'agent@shekel.test') }

    it 'signs an existing agent in through the SSO token' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test')

        complete_callback

        expect(response).to redirect_to(%r{\A#{frontend_url}/app/login\?})
        query = Rack::Utils.parse_query(URI.parse(response.location).query)
        expect(CGI.unescape(query['email'])).to eq(agent.email) # upstream double-encodes
        expect(query['sso_auth_token']).to be_present
        expect(query).not_to have_key('error')
      end
    end

    it 'matches the agent by email case-insensitively' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'Agent@Shekel.TEST')

        complete_callback

        query = Rack::Utils.parse_query(URI.parse(response.location).query)
        expect(CGI.unescape(query['email'])).to eq(agent.email) # upstream double-encodes
        expect(query['sso_auth_token']).to be_present
      end
    end

    it 'an_unknown_email_is_provisioned_now' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'stranger@shekel.test')

        expect { complete_callback }.to change(User, :count).by(1)

        user = User.from_email('stranger@shekel.test')
        expect(account.account_users.find_by!(user: user).role).to eq('agent')
        expect(CGI.unescape(redirect_query['email'])).to eq(user.email) # upstream double-encodes
        expect(redirect_query['sso_auth_token']).to be_present
        expect(redirect_query).not_to have_key('error')
      end
    end

    it 'does not create an account of its own for a provisioned user' do
      with_modified_env(**shekel_env, ENABLE_ACCOUNT_SIGNUP: 'true') do
        mock_shekel_auth(email: 'stranger@shekel.test')

        expect { complete_callback }.not_to change(Account, :count)
      end
    end

    it 'the_sync_runs_before_the_sso_redirect' do
      team = create(:team, account: account)
      Shekel::TenantTeam.create!(account: account, tenant_id: tenant_id, team: team)

      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test', tenants: [tenant_claim(tenant_id.upcase)], scope: admin_scope)

        complete_callback

        expect(redirect_query['sso_auth_token']).to be_present
        expect(team.members).to include(agent)
        expect(account.account_users.find_by!(user: agent).role).to eq('administrator')
      end
    end

    it 'syncs an agent without the CRM admin scope as an agent' do
      create(:account_user, account: account, user: agent, role: :administrator)

      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test', scope: access_scope)

        complete_callback

        expect(account.account_users.find_by!(user: agent).role).to eq('agent')
      end
    end

    it 'missing_tenants_claim_leaves_teams_unchanged' do
      team = create(:team, account: account)
      Shekel::TenantTeam.create!(account: account, tenant_id: tenant_id, team: team)
      team.add_members([agent.id])
      allow(Rails.logger).to receive(:warn)

      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test', tenants: nil, scope: admin_scope)

        complete_callback

        expect(redirect_query['sso_auth_token']).to be_present
        expect(team.reload.members).to include(agent)
        expect(account.account_users.find_by!(user: agent).role).to eq('administrator')
        expect(Rails.logger).to have_received(:warn).with(/tenants claim/)
      end
    end

    it 'an_explicit_empty_tenants_claim_leaves_mapped_teams' do
      team = create(:team, account: account)
      Shekel::TenantTeam.create!(account: account, tenant_id: tenant_id, team: team)
      team.add_members([agent.id])

      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test', tenants: [])

        complete_callback

        expect(team.reload.members).not_to include(agent)
      end
    end

    it 'a_token_without_customer_comms_access_is_refused' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'stranger@shekel.test', scope: 'openid email profile tenants customer_comms.admin')

        expect { expect_refused_at_first_hop }.not_to change(User, :count)
      end
    end

    it 'a_blank_email_is_refused' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: '')

        expect { expect_refused_at_first_hop }.not_to change(User, :count)
      end
    end

    it 'a_missing_account_id_redirects_with_shekel_misconfigured' do
      allow(Rails.logger).to receive(:error)

      with_modified_env(**shekel_env, SHEKEL_CHATWOOT_ACCOUNT_ID: nil) do
        mock_shekel_auth(email: 'stranger@shekel.test')

        expect { get '/omniauth/shekel/callback' }.not_to change(User, :count)

        expect(response).to redirect_to("#{frontend_url}/app/login?error=shekel-misconfigured")
        expect(Rails.logger).to have_received(:error).with(/SHEKEL_CHATWOOT_ACCOUNT_ID/)
      end
    end

    it 'an_account_id_that_names_no_account_redirects_with_shekel_misconfigured' do
      allow(Rails.logger).to receive(:error)

      with_modified_env(**shekel_env, SHEKEL_CHATWOOT_ACCOUNT_ID: (Account.maximum(:id).to_i + 1000).to_s) do
        mock_shekel_auth(email: 'stranger@shekel.test')

        get '/omniauth/shekel/callback'

        expect(response).to redirect_to("#{frontend_url}/app/login?error=shekel-misconfigured")
        # Nothing carried over: the second hop is still refused.
        get '/auth/shekel/callback'
        expect(response).to redirect_to("#{frontend_url}/app/login?error=no-account-found")
      end
    end

    it 'a_user_realm_token_with_tenants_is_still_refused' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'stranger@shekel.test', realm: 'user', tenants: [tenant_claim(tenant_id)], scope: admin_scope)

        expect { expect_refused_at_first_hop }.not_to change(User, :count)
      end
    end

    it 'refuses a token from the customer realm even when the email matches an agent' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test', realm: 'user')

        expect_refused_at_first_hop
      end
    end

    it 'refuses a token with no realm claim' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test', realm: nil)

        expect_refused_at_first_hop
      end
    end

    it 'refuses the second hop when the realm check was not passed in this session' do
      with_modified_env(**shekel_env) do
        mock_shekel_auth(email: 'agent@shekel.test')
        complete_callback
        expect(response.location).to include('sso_auth_token=')

        # Replaying the second hop must not sign in again: the flag is one-shot.
        get '/auth/shekel/callback'
        expect(response).to redirect_to("#{frontend_url}/app/login?error=no-account-found")
      end
    end
  end

  describe 'request phase' do
    around do |example|
      test_mode = OmniAuth.config.test_mode
      OmniAuth.config.test_mode = false
      example.run
    ensure
      OmniAuth.config.test_mode = test_mode
    end

    it 'redirects to the admin-realm authorize endpoint with PKCE, state and nonce' do
      with_modified_env(**shekel_env) do
        post '/omniauth/shekel'

        location = URI.parse(response.location)
        query = Rack::Utils.parse_query(location.query)
        expect("#{location.scheme}://#{location.host}#{location.path}").to eq('https://auth.example.test/oauth/admin/authorize')
        expect(query).to include(
          'client_id' => 'chatwoot-test-client',
          'redirect_uri' => "#{frontend_url}/omniauth/shekel/callback",
          'response_type' => 'code',
          'scope' => 'openid email profile tenants customer_comms.access customer_comms.admin',
          'code_challenge_method' => 'S256'
        )
        expect(query['code_challenge']).to be_present
        expect(query['state']).to be_present
        expect(query['nonce']).to be_present
      end
    end

    it 'never redirects to the provider when it is not configured' do
      with_modified_env(**shekel_env, SHEKEL_OIDC_CLIENT_ID: nil) do
        # OmniAuth logs the setup KeyError and sends the browser to its failure endpoint.
        post '/omniauth/shekel'

        expect(response).to have_http_status(:redirect)
        expect(response.location).not_to include('auth.example.test')
      end
    end
  end

  # No mock auth hash here: the real omniauth_openid_connect strategy runs the
  # code exchange against stubbed provider endpoints, to pin down where the
  # tenants claim and the granted scope actually arrive.
  describe 'full code flow through the strategy' do
    let(:signing_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:team) { create(:team, account: account) }

    around do |example|
      test_mode = OmniAuth.config.test_mode
      OmniAuth.config.test_mode = false
      example.run
    ensure
      OmniAuth.config.test_mode = test_mode
    end

    before do
      Shekel::TenantTeam.create!(account: account, tenant_id: tenant_id, team: team)
    end

    def id_token_for(nonce, tenants)
      claims = {
        iss: 'https://auth.example.test/oauth/admin', aud: 'chatwoot-test-client', sub: '42', nonce: nonce,
        iat: Time.now.to_i, exp: 5.minutes.from_now.to_i, email: 'ada@shekel.test', realm: 'admin', tenants: tenants
      }
      JSON::JWT.new(claims).tap { |jwt| jwt.kid = 'test-key' }.sign(signing_key, :RS256).to_s
    end

    def stub_provider(nonce:, scope:, tenants:)
      jwks = { keys: [JSON::JWK.new(signing_key.public_key, kid: 'test-key')] }
      stub_request(:get, 'https://auth.example.test/oauth/jwks').to_return(
        status: 200, body: jwks.to_json, headers: { 'Content-Type' => 'application/json' }
      )
      stub_request(:post, 'https://auth.example.test/oauth/admin/token').to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: { access_token: 'opaque-access-token', token_type: 'Bearer', expires_in: 3600, scope: scope,
                id_token: id_token_for(nonce, tenants) }.to_json
      )
      stub_request(:get, 'https://auth.example.test/oauth/admin/userinfo').to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: { sub: '42', email: 'ada@shekel.test', name: 'Ada Admin', realm: 'admin', tenants: tenants }.to_json
      )
    end

    def sign_in_through_provider(scope:, tenants:)
      post '/omniauth/shekel'
      authorize = Rack::Utils.parse_query(URI.parse(response.location).query)
      stub_provider(nonce: authorize['nonce'], scope: scope, tenants: tenants)

      get '/omniauth/shekel/callback', params: { code: 'auth-code', state: authorize['state'] }
      expect(response).to redirect_to("#{frontend_url}/auth/shekel/callback")
      follow_redirect!
    end

    it 'reads tenants from raw_info and the CRM admin grant from credentials.scope' do
      with_modified_env(**shekel_env) do
        sign_in_through_provider(scope: admin_scope, tenants: [tenant_claim(tenant_id)])

        user = User.from_email('ada@shekel.test')
        expect(redirect_query['sso_auth_token']).to be_present
        expect(team.members).to include(user)
        expect(account.account_users.find_by!(user: user).role).to eq('administrator')
      end
    end

    it 'syncs an agent when the token response grants only CRM access' do
      with_modified_env(**shekel_env) do
        sign_in_through_provider(scope: access_scope, tenants: [])

        user = User.from_email('ada@shekel.test')
        expect(team.members).not_to include(user)
        expect(account.account_users.find_by!(user: user).role).to eq('agent')
      end
    end
  end
end
