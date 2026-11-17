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

  context 'with SHEKEL_PUBLIC_HOST set' do
    around { |example| with_modified_env(SHEKEL_PUBLIC_HOST: public_host) { example.run } }

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

    it 'compares the host case-insensitively, ignoring the port and a trailing dot' do
      ['CRM-Hooks.Example.Test', "#{public_host}:8443", "#{public_host}."].each do |host|
        request_as(host, :get, '/api/v1/profile')
        expect_bare_404
      end
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

  it 'no_guard_when_public_host_is_unset' do
    with_modified_env(SHEKEL_PUBLIC_HOST: nil) do
      request_as(public_host, :get, '/health')
      expect(response).to have_http_status(:success)

      request_as(public_host, :get, '/auth/validate_token')
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'treats a blank SHEKEL_PUBLIC_HOST as unset' do
    with_modified_env(SHEKEL_PUBLIC_HOST: '') do
      request_as('', :get, '/health')
      expect(response).to have_http_status(:success)
    end
  end
end
