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
      SHEKEL_OIDC_DISCOVERY: nil
    }
  end

  def mock_shekel_auth(email:, realm: 'admin')
    raw_info = { sub: '42', email: email, name: 'Ada Admin', realm: realm }.compact
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:shekel] = OmniAuth::AuthHash.new(
      provider: 'shekel',
      uid: '42',
      info: { name: 'Ada Admin', email: email },
      extra: { raw_info: raw_info }
    )
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

    it 'refuses an email that has no agent and creates nothing' do
      with_modified_env(**shekel_env, ENABLE_ACCOUNT_SIGNUP: 'true') do
        mock_shekel_auth(email: 'stranger@shekel.test')

        expect { complete_callback }.not_to change(User, :count)

        expect(response).to redirect_to("#{frontend_url}/app/login?error=no-account-found")
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
          'scope' => 'openid email profile',
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
end
