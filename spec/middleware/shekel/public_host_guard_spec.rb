require 'rails_helper'

# Runs through the full middleware stack: the guard has to sit in front of
# ActionCable, OmniAuth, Active Storage and the router.
RSpec.describe Shekel::PublicHostGuard, type: :request do
  let(:public_host) { 'crm-hooks.example.test' }
  let(:vpn_host) { 'crm.example.test' }
  let(:webhook_path) { '/webhooks/whatsapp/+1234567890' }
  let(:client_secret) { 'test-whatsapp-secret' }
  let(:body) { { object: 'whatsapp_business_account', entry: [] }.to_json }

  def signature_for(payload, secret = client_secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def request_as(host, verb, path, **)
    host! host
    send(verb, path, **)
  end

  def expect_bare_404
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq('')
  end

  before do
    InstallationConfig.where(name: 'WHATSAPP_APP_SECRET').delete_all
    GlobalConfig.clear_cache
  end

  describe 'ALLOWED' do
    it 'lists only the WhatsApp webhook verbs and is frozen' do
      expect(described_class::ALLOWED).to be_frozen
      expect(described_class::ALLOWED.map(&:first)).to contain_exactly('GET', 'POST')
    end
  end

  context 'with SHEKEL_STAFF_HOSTS and SHEKEL_PUBLIC_HOST set' do
    around { |example| with_modified_env(SHEKEL_STAFF_HOSTS: "#{vpn_host},crm-admin.example.test", SHEKEL_PUBLIC_HOST: public_host) { example.run } }

    it 'whatsapp_verify_get_and_signed_post_pass_through' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      path = "/webhooks/whatsapp/#{channel.phone_number}"

      # The verify action answers 401 without the right token: the controller was reached.
      request_as(public_host, :get, path)
      expect(response).to have_http_status(:unauthorized)

      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      with_modified_env(WHATSAPP_APP_SECRET: client_secret) do
        request_as(public_host, :post, path, params: body,
                                             headers: { 'CONTENT_TYPE' => 'application/json',
                                                        'X-Hub-Signature-256' => signature_for(body) })
        expect(response).to have_http_status(:success)
        expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)

        # The body is untouched, so a bad signature is still rejected by the controller itself.
        request_as(public_host, :post, path, params: body,
                                             headers: { 'CONTENT_TYPE' => 'application/json',
                                                        'X-Hub-Signature-256' => 'sha256=invalid' })
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'dashboard_api_auth_omniauth_cable_active_storage_and_super_admin_return_404' do
      [
        [:get, '/'],
        [:get, '/app/login'],
        [:get, '/app/accounts/1/dashboard'],
        [:get, '/api/v1/profile'],
        [:post, '/api/v1/accounts/1/conversations'],
        [:post, '/auth/sign_in'],
        [:get, '/auth/validate_token'],
        [:get, '/omniauth/shekel/callback'],
        [:post, '/auth/shekel'],
        [:get, '/cable'],
        [:get, '/rails/active_storage/blobs/redirect/abc/file.png'],
        [:get, '/rails/active_storage/disk/abc/file.png'],
        [:get, '/super_admin'],
        [:get, '/monitoring/sidekiq'],
        [:get, '/health'],
        [:get, '/widget'],
        [:get, '/packs/js/application.js']
      ].each do |verb, path|
        request_as(public_host, verb, path)
        expect_bare_404
      end
    end

    it 'wrong_verb_or_extra_segment_returns_404' do
      %i[put patch delete head options].each do |verb|
        request_as(public_host, verb, webhook_path)
        expect(response).to have_http_status(:not_found)
        expect(response.body).to eq('')
      end

      rejected_paths = [
        '/webhooks/whatsapp',
        '/webhooks/whatsapp/',
        '/webhooks/whatsapp/+1234567890/',
        '/webhooks/whatsapp/+1234567890/extra',
        '/webhooks/whatsapp/+1234567890.json',
        '/webhooks/whatsapp/12345',
        '/webhooks/whatsapp/1234567890123456',
        '/webhooks/whatsapp/abc1234567',
        '/webhooks/whatsapp/%2B1234567890/../../api/v1/profile',
        '/webhooks/whatsapp/+1234567890%0A',
        '/webhooks/telegram/abc',
        '/webhooks/whatsapp//+1234567890'
      ]
      rejected_paths.product(%i[get post]).each do |path, verb|
        request_as(public_host, verb, path)
        expect_bare_404
      end
    end

    it 'answers CORS preflights with the bare 404 too, because the guard sits ahead of Rack::Cors' do
      request_as(public_host, :options, '/packs/application.js',
                 headers: { 'Origin' => 'https://evil.example.test', 'Access-Control-Request-Method' => 'GET' })
      expect_bare_404
      expect(response.headers.keys.map(&:downcase)).not_to include('access-control-allow-origin')
    end

    it 'matches the path without its query string' do
      request_as(public_host, :get, "#{webhook_path}?hub.mode=subscribe")
      expect(response).to have_http_status(:unauthorized)

      request_as(public_host, :get, "/api/v1/profile?x=#{webhook_path}")
      expect_bare_404
    end

    it 'compares the host case-insensitively, ignoring the port and trailing dots' do
      ['CRM-Hooks.Example.Test', "#{public_host}:8443", "#{public_host}.", "#{public_host}.."].each do |host|
        request_as(host, :get, '/api/v1/profile')
        expect_bare_404
      end

      ['CRM.Example.Test', "#{vpn_host}:3000", "#{vpn_host}.", "#{vpn_host}.."].each do |host|
        request_as(host, :get, '/auth/validate_token')
        expect(response).to have_http_status(:unauthorized), "#{host} was not let through"
      end
    end

    it 'restricts a Host that is not a staff host, not only the public one' do
      ['crm-hooks.example.test.evil.test', 'unknown.example.test', '10.0.0.5', 'localhost', "#{vpn_host}.evil.test"].each do |host|
        request_as(host, :get, '/api/v1/profile')
        expect_bare_404

        request_as(host, :get, webhook_path)
        expect(response).to have_http_status(:unauthorized), "#{host} did not reach the webhook"
      end
    end

    it 'restricts a request with an empty or missing Host' do
      app = ->(_env) { [200, {}, ['reached']] }
      guard = described_class.new(app)

      [{ 'HTTP_HOST' => '' }, { 'HTTP_HOST' => nil, 'SERVER_NAME' => vpn_host }].each do |headers|
        expect(guard.call(Rack::MockRequest.env_for('/api/v1/profile', headers)).first).to eq(404)
        expect(guard.call(Rack::MockRequest.env_for(webhook_path, headers)).first).to eq(200)
      end
    end

    it 'gives every listed staff host full access' do
      request_as('crm-admin.example.test', :get, '/health')
      expect(response).to have_http_status(:success)
    end

    it 'does not trust X-Forwarded-Host' do
      # Spoofing the VPN host through the forwarded header must not lift the guard.
      request_as(public_host, :get, '/api/v1/profile', headers: { 'X-Forwarded-Host' => vpn_host })
      expect_bare_404

      # And a forwarded public host does not turn the VPN host into the public one.
      request_as(vpn_host, :get, '/auth/validate_token', headers: { 'X-Forwarded-Host' => public_host })
      expect(response).to have_http_status(:unauthorized)
    end

    it 'the_vpn_host_is_unaffected' do
      request_as(vpn_host, :get, '/auth/validate_token')
      expect(response).to have_http_status(:unauthorized)

      request_as(vpn_host, :get, '/api/v1/profile')
      expect(response).to have_http_status(:unauthorized)

      request_as(vpn_host, :get, '/health')
      expect(response).to have_http_status(:success)

      request_as(vpn_host, :get, webhook_path)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'with only SHEKEL_PUBLIC_HOST set' do
    around { |example| with_modified_env(SHEKEL_STAFF_HOSTS: nil, SHEKEL_PUBLIC_HOST: public_host) { example.run } }

    it 'restricts every Host, the VPN host included, and warns' do
      allow(Rails.logger).to receive(:warn)

      [public_host, vpn_host].each do |host|
        request_as(host, :get, '/health')
        expect_bare_404
      end
      request_as(vpn_host, :get, webhook_path)
      expect(response).to have_http_status(:unauthorized)
      expect(Rails.logger).to have_received(:warn).with(/SHEKEL_STAFF_HOSTS and SHEKEL_PUBLIC_HOST/).at_most(:once)
    end
  end

  context 'with only SHEKEL_STAFF_HOSTS set' do
    around { |example| with_modified_env(SHEKEL_STAFF_HOSTS: vpn_host, SHEKEL_PUBLIC_HOST: nil) { example.run } }

    it 'gives the staff host full access and restricts every other Host' do
      request_as(vpn_host, :get, '/health')
      expect(response).to have_http_status(:success)

      request_as(public_host, :get, '/health')
      expect_bare_404
    end

    it 'warns once per process' do
      allow(Rails.logger).to receive(:warn)
      guard = described_class.new(->(_env) { [200, {}, []] })

      2.times { guard.call(Rack::MockRequest.env_for('/health', 'HTTP_HOST' => public_host)) }
      expect(Rails.logger).to have_received(:warn).with(/SHEKEL_STAFF_HOSTS and SHEKEL_PUBLIC_HOST/).once
    end
  end

  it 'no_guard_when_staff_hosts_and_public_host_are_unset' do
    with_modified_env(SHEKEL_STAFF_HOSTS: nil, SHEKEL_PUBLIC_HOST: nil) do
      request_as(public_host, :get, '/health')
      expect(response).to have_http_status(:success)

      request_as(public_host, :get, '/auth/validate_token')
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'treats blank values as unset' do
    with_modified_env(SHEKEL_STAFF_HOSTS: ' ', SHEKEL_PUBLIC_HOST: '') do
      request_as('', :get, '/health')
      expect(response).to have_http_status(:success)
    end
  end
end
