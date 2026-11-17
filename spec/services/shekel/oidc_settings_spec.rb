require 'rails_helper'

RSpec.describe Shekel::OidcSettings do
  let(:base_env) do
    {
      SHEKEL_OIDC_ISSUER: 'https://auth.example.test/oauth/admin',
      SHEKEL_OIDC_CLIENT_ID: 'chatwoot-test-client',
      SHEKEL_OIDC_CLIENT_SECRET: 'test-secret',
      SHEKEL_OIDC_REDIRECT_URI: 'http://localhost:3000/omniauth/shekel/callback',
      # Clear anything a developer's .env (loaded by docker compose) might set.
      SHEKEL_OIDC_AUTHORIZE_URL: nil,
      SHEKEL_OIDC_TOKEN_URL: nil,
      SHEKEL_OIDC_USERINFO_URL: nil,
      SHEKEL_OIDC_JWKS_URL: nil,
      SHEKEL_OIDC_DISCOVERY: nil
    }
  end

  describe '.enabled?' do
    it 'is false without a client id' do
      with_modified_env(SHEKEL_OIDC_CLIENT_ID: nil) do
        expect(described_class.enabled?).to be(false)
      end
    end

    it 'is true with a client id' do
      with_modified_env(SHEKEL_OIDC_CLIENT_ID: 'chatwoot-test-client') do
        expect(described_class.enabled?).to be(true)
      end
    end
  end

  describe '.strategy_options' do
    it 'requires explicit endpoints when discovery is off' do
      with_modified_env(**base_env) do
        expect { described_class.strategy_options }.to raise_error(KeyError, /SHEKEL_OIDC_AUTHORIZE_URL/)
      end
    end

    it 'uses PKCE, the issuer host and the configured endpoints' do
      env = base_env.merge(
        SHEKEL_OIDC_AUTHORIZE_URL: 'https://auth.example.test/oauth/admin/authorize',
        SHEKEL_OIDC_TOKEN_URL: 'https://auth.example.test/oauth/admin/token',
        SHEKEL_OIDC_USERINFO_URL: 'https://auth.example.test/oauth/admin/userinfo',
        SHEKEL_OIDC_JWKS_URL: 'https://auth.example.test/oauth/jwks'
      )

      with_modified_env(**env) do
        options = described_class.strategy_options

        expect(options).to include(issuer: 'https://auth.example.test/oauth/admin', discovery: false, pkce: true, send_nonce: true,
                                   client_signing_alg: :RS256, client_auth_method: :basic)
        expect(options[:client_options]).to include(
          host: 'auth.example.test',
          scheme: 'https',
          port: 443,
          token_endpoint: 'https://auth.example.test/oauth/admin/token',
          jwks_uri: 'https://auth.example.test/oauth/jwks'
        )
      end
    end

    it 'leaves the endpoints to discovery when discovery is on' do
      with_modified_env(**base_env, SHEKEL_OIDC_DISCOVERY: 'true') do
        options = described_class.strategy_options

        expect(options[:discovery]).to be(true)
        expect(options[:client_options]).not_to have_key(:authorization_endpoint)
      end
    end
  end
end
