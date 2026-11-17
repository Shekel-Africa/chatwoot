# Shekel fork: an allowlist of hosts. Staff reach the dashboard, the API,
# sign-in and /cable on the hosts in SHEKEL_STAFF_HOSTS (the VPN host). Every
# other Host, the public one Meta delivers WhatsApp webhooks to included, may
# reach only the verb + path pairs in ALLOWED; everything else gets a bare 404
# (no body, no Rails error page). This is the app-level layer behind the WAF and
# the reverse proxy, and fails closed: an unknown, empty or mistyped Host is
# restricted, not let through.
#
# It is the first middleware, so it also covers what Rails mounts as Rack apps
# (ActionCable, Active Storage, Sidekiq Web, OmniAuth). The request body is never
# read, so the controller still verifies Meta's signature over the raw payload.
#
# Only Host is trusted. X-Forwarded-Host is ignored: the proxy must set Host.
# The guard is off only when both SHEKEL_STAFF_HOSTS and SHEKEL_PUBLIC_HOST are
# unset (local development). With only one of them set it warns once and still
# enforces: with no staff hosts listed, every Host is restricted.
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

    def self.normalize_host(host)
      Shekel::OidcSettings.normalize_host(host)
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      staff_hosts = Shekel::OidcSettings.staff_hosts
      public_host = Shekel::OidcSettings.public_host
      return @app.call(env) if staff_hosts.empty? && public_host.nil?

      warn_partial_configuration if staff_hosts.empty? || public_host.nil?
      return @app.call(env) if staff_hosts.include?(self.class.normalize_host(env['HTTP_HOST']))
      return @app.call(env) if allowed?(env['REQUEST_METHOD'], env['PATH_INFO'].to_s)

      # Fresh header hash: middleware in front of this one (CORS) writes to it.
      [404, { 'content-length' => '0' }, []]
    end

    private

    # HEAD is deliberately not allowed: Meta only issues GET and POST.
    def allowed?(verb, path)
      ALLOWED.any? { |allowed_verb, pattern| allowed_verb == verb && pattern.match?(path) }
    end

    # Once per process: the guard runs on every request.
    def warn_partial_configuration
      return if @partial_configuration_warned

      @partial_configuration_warned = true
      Rails.logger.warn('[shekel] Set both SHEKEL_STAFF_HOSTS and SHEKEL_PUBLIC_HOST: only one is set, so every Host ' \
                        'outside SHEKEL_STAFF_HOSTS (all of them if it is unset) gets the webhook paths only')
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
