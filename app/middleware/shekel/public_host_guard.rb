# Shekel fork: the public hostname exists only so Meta can deliver WhatsApp
# webhooks. Staff reach the dashboard, the API, sign-in and /cable over the VPN
# host. This is the app-level layer behind the WAF and the reverse proxy: when
# the request's Host is SHEKEL_PUBLIC_HOST, only the verb + path pairs in
# ALLOWED pass; everything else gets a bare 404 (no body, no Rails error page).
#
# It is the first middleware, so it also covers what Rails mounts as Rack apps
# (ActionCable, Active Storage, Sidekiq Web, OmniAuth). The request body is never
# read, so the controller still verifies Meta's signature over the raw payload.
#
# Only Host is trusted. X-Forwarded-Host is ignored: the proxy must set Host.
# Local development leaves SHEKEL_PUBLIC_HOST unset and the guard does nothing.
#
# Inserted by config/initializers/zz_shekel_public_host_guard.rb, which loads
# last so that nothing (Rack::Cors answers preflights for some paths) is ahead of it.
# rubocop:disable Style/ClassAndModuleChildren
module Shekel
  class PublicHostGuard
    WHATSAPP_WEBHOOK = %r{\A/webhooks/whatsapp/\+?\d{6,15}\z}

    ALLOWED = [
      ['GET', WHATSAPP_WEBHOOK].freeze,
      ['POST', WHATSAPP_WEBHOOK].freeze
    ].freeze

    # Case-insensitive, port and trailing dot ignored.
    def self.normalize_host(host)
      host.to_s.downcase.sub(/:\d+\z/, '').chomp('.')
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      public_host = Shekel::OidcSettings.public_host
      return @app.call(env) if public_host.nil? || normalize_host(request_host(env)) != public_host
      return @app.call(env) if allowed?(env['REQUEST_METHOD'], env['PATH_INFO'].to_s)

      # Fresh header hash: middleware in front of this one (CORS) writes to it.
      [404, { 'content-length' => '0' }, []]
    end

    private

    # HEAD is deliberately not allowed: Meta only issues GET and POST.
    def allowed?(verb, path)
      ALLOWED.any? { |allowed_verb, pattern| allowed_verb == verb && pattern.match?(path) }
    end

    def request_host(env)
      env['HTTP_HOST'].presence || env['SERVER_NAME']
    end

    def normalize_host(host)
      self.class.normalize_host(host)
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
