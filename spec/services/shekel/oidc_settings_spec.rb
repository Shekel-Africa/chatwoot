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

  describe '.staff_mode?' do
    it 'follows SHEKEL_CHATWOOT_ACCOUNT_ID, not the OIDC client id' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil, SHEKEL_OIDC_CLIENT_ID: 'chatwoot-test-client') do
        expect(described_class.staff_mode?).to be(false)
      end
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '  ') { expect(described_class.staff_mode?).to be(false) }
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7', SHEKEL_OIDC_CLIENT_ID: nil) { expect(described_class.staff_mode?).to be(true) }
    end
  end

  describe '.password_login_disabled?' do
    it 'follows staff_mode?' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil) { expect(described_class.password_login_disabled?).to be(false) }
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7', SHEKEL_OIDC_CLIENT_ID: nil) { expect(described_class.password_login_disabled?).to be(true) }
    end
  end

  describe '.token_lifespan' do
    it 'is SHEKEL_SESSION_LIFESPAN_HOURS (default 12) in staff mode and upstream otherwise' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil) { expect(described_class.token_lifespan(2.months)).to eq(2.months) }
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7', SHEKEL_SESSION_LIFESPAN_HOURS: nil) do
        expect(described_class.token_lifespan(2.months)).to eq(12.hours)
      end
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7', SHEKEL_SESSION_LIFESPAN_HOURS: '8') do
        expect(described_class.token_lifespan(2.months)).to eq(8.hours)
      end
    end
  end

  describe '.verify_configuration!' do
    let(:production) { ActiveSupport::EnvironmentInquirer.new('production') }

    it 'refuses to boot production in staff mode without an OIDC client id' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7', SHEKEL_OIDC_CLIENT_ID: nil) do
        expect { described_class.verify_configuration!(env: production) }.to raise_error(RuntimeError, /SHEKEL_OIDC_CLIENT_ID is blank/)
        expect { described_class.verify_configuration!(env: ActiveSupport::EnvironmentInquirer.new('test')) }.not_to raise_error
      end
    end

    it 'boots production when staff mode is configured or off' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7', SHEKEL_OIDC_CLIENT_ID: 'chatwoot-test-client') do
        expect { described_class.verify_configuration!(env: production) }.not_to raise_error
      end
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil, SHEKEL_OIDC_CLIENT_ID: nil) do
        expect { described_class.verify_configuration!(env: production) }.not_to raise_error
      end
    end
  end

  describe '.account_id' do
    it 'reads SHEKEL_CHATWOOT_ACCOUNT_ID' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: '7') { expect(described_class.account_id).to eq(7) }
    end

    it 'fails loudly when it is not set' do
      with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil) do
        expect { described_class.account_id }.to raise_error(KeyError, /SHEKEL_CHATWOOT_ACCOUNT_ID/)
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
        expect(options[:scope]).to eq(%i[openid email profile tenants customer_comms.access customer_comms.admin])
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

  describe '.public_host' do
    before { described_class.instance_variable_set(:@warned_hosts, nil) }

    it 'is nil when unset or blank' do
      with_modified_env(SHEKEL_PUBLIC_HOST: nil) { expect(described_class.public_host).to be_nil }
      with_modified_env(SHEKEL_PUBLIC_HOST: '  ') { expect(described_class.public_host).to be_nil }
    end

    it 'returns a bare hostname unchanged, without warning' do
      allow(Rails.logger).to receive(:warn)
      with_modified_env(SHEKEL_PUBLIC_HOST: 'crm-hooks.example.test') do
        expect(described_class.public_host).to eq('crm-hooks.example.test')
      end
      expect(Rails.logger).not_to have_received(:warn)
    end

    it 'strips scheme, path, port and case, and warns once' do
      allow(Rails.logger).to receive(:warn)
      with_modified_env(SHEKEL_PUBLIC_HOST: 'HTTPS://CRM-Hooks.Example.test:8443/webhooks/') do
        expect(described_class.public_host).to eq('crm-hooks.example.test')
        described_class.public_host
      end
      expect(Rails.logger).to have_received(:warn).with(/bare hostname/).once
    end

    it 'strips every trailing dot' do
      allow(Rails.logger).to receive(:warn)
      with_modified_env(SHEKEL_PUBLIC_HOST: 'crm-hooks.example.test..') do
        expect(described_class.public_host).to eq('crm-hooks.example.test')
      end
    end

    it 'warns when the value is not a hostname' do
      allow(Rails.logger).to receive(:warn)
      with_modified_env(SHEKEL_PUBLIC_HOST: 'not a host') do
        described_class.public_host
      end
      expect(Rails.logger).to have_received(:warn).with(/bare hostname/)
    end
  end

  describe '.staff_hosts' do
    before { described_class.instance_variable_set(:@warned_hosts, nil) }

    it 'is empty when unset or blank' do
      with_modified_env(SHEKEL_STAFF_HOSTS: nil) { expect(described_class.staff_hosts).to eq([]) }
      with_modified_env(SHEKEL_STAFF_HOSTS: ' , ') { expect(described_class.staff_hosts).to eq([]) }
    end

    it 'normalises each comma-separated host like the public host' do
      allow(Rails.logger).to receive(:warn)
      with_modified_env(SHEKEL_STAFF_HOSTS: 'crm.example.test, HTTPS://CRM-Admin.Example.test:443/app,crm.vpn.test..') do
        expect(described_class.staff_hosts).to eq(%w[crm.example.test crm-admin.example.test crm.vpn.test])
      end
      expect(Rails.logger).to have_received(:warn).with(/SHEKEL_STAFF_HOSTS/).once
    end
  end
end
