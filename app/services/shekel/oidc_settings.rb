# Shekel fork: staff sign-in through authentication-api's admin realm (OIDC).
#
# The `shekel` OmniAuth provider is always mounted, like upstream's
# google_oauth2 one, and reads its settings from ENV on each request through
# OmniAuth's setup phase. It is offered on the login page only when
# SHEKEL_OIDC_CLIENT_ID is set. Required settings are read with ENV.fetch so a
# half-configured provider fails loudly instead of redirecting somewhere wrong.
#
# Staff mode (SHEKEL_CHATWOOT_ACCOUNT_ID set) is what turns the restrictions on:
# team-scoped visibility, no password or other SSO sign-in, no personal API
# tokens and the short session. It keys on the account id rather than the OIDC
# client id so that losing the OIDC settings fails closed (nobody signs in)
# instead of open (everyone sees everything); production refuses to boot in
# that state (config/initializers/shekel_staff_mode.rb).
#
# See docs/shekel/LOCAL_OIDC_LOGIN.md for the variables and the client to register.
class Shekel::OidcSettings
  PROVIDER = 'shekel'.freeze
  # `tenants` adds the tenants claim; `customer_comms.access` is required to
  # sign in at all and `customer_comms.admin` is granted to CRM admins only.
  SCOPES = %i[openid email profile tenants customer_comms.access customer_comms.admin].freeze
  ACCESS_SCOPE = 'customer_comms.access'.freeze
  ADMIN_SCOPE = 'customer_comms.admin'.freeze

  def self.enabled?
    ENV.fetch('SHEKEL_OIDC_CLIENT_ID', '').present?
  end

  # The Shekel deployment: staff are provisioned into SHEKEL_CHATWOOT_ACCOUNT_ID
  # and every Shekel restriction applies. Unset in development and upstream specs.
  def self.staff_mode?
    ENV.fetch('SHEKEL_CHATWOOT_ACCOUNT_ID', '').strip.present?
  end

  # In staff mode, staff sign in through Shekel only.
  def self.password_login_disabled?
    staff_mode?
  end

  # devise_token_auth session lifespan (config/initializers/devise_token_auth.rb):
  # SHEKEL_SESSION_LIFESPAN_HOURS (default 12) in staff mode, upstream's otherwise.
  def self.token_lifespan(upstream)
    return upstream unless staff_mode?

    Integer(ENV.fetch('SHEKEL_SESSION_LIFESPAN_HOURS', '12')).hours
  end

  # Raised at boot in production (config/initializers/shekel_staff_mode.rb):
  # staff mode with no Shekel sign-in would leave nobody able to sign in.
  def self.verify_configuration!(env: Rails.env)
    return unless env.production? && staff_mode? && !enabled?

    raise 'Shekel staff mode is on (SHEKEL_CHATWOOT_ACCOUNT_ID is set) but SHEKEL_OIDC_CLIENT_ID is blank: ' \
          'set the SHEKEL_OIDC_* variables (docs/shekel/LOCAL_OIDC_LOGIN.md) or unset SHEKEL_CHATWOOT_ACCOUNT_ID'
  end

  # Hostname Meta delivers webhooks to. Requests on it may reach only the channel
  # webhook paths (Shekel::PublicHostGuard). Nil leaves the guard off, for local
  # development.
  def self.public_host
    raw = ENV.fetch('SHEKEL_PUBLIC_HOST', '').strip
    return nil if raw.empty?

    host = raw.downcase.sub(%r{\A[a-z][a-z0-9+.-]*://}, '').sub(%r{[/?#].*\z}, '').sub(/:\d+\z/, '').chomp('.')
    warn_public_host(host) if host != raw.downcase || !host.match?(HOSTNAME)
    host
  end

  HOSTNAME = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/
  private_constant :HOSTNAME

  # Logs once per process: public_host runs on every request.
  def self.warn_public_host(host)
    return if @public_host_warned

    @public_host_warned = true
    Rails.logger.warn("[shekel] SHEKEL_PUBLIC_HOST should be a bare hostname; using #{host.inspect} after normalising")
  end
  private_class_method :warn_public_host

  # The one Chatwoot account that Shekel staff are provisioned into.
  def self.account_id
    Integer(ENV.fetch('SHEKEL_CHATWOOT_ACCOUNT_ID'))
  end

  def self.discovery?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('SHEKEL_OIDC_DISCOVERY', false))
  end

  # Called from the OmniAuth setup phase with the strategy for this request.
  def self.apply(strategy)
    raise KeyError, 'SHEKEL_OIDC_CLIENT_ID is not set; Shekel sign-in is disabled' unless enabled?

    strategy.options.merge!(strategy_options)
  end

  def self.strategy_options
    issuer = ENV.fetch('SHEKEL_OIDC_ISSUER')

    {
      issuer: issuer,
      discovery: discovery?,
      scope: SCOPES,
      response_type: 'code',
      pkce: true,
      send_nonce: true,
      # authentication-api signs ID tokens with RS256 only. Pinning it stops the
      # strategy from ever accepting an HS256 token keyed on the client secret.
      client_signing_alg: :RS256,
      # The scope belongs on the authorization request only (RFC 6749 §4.1.3).
      send_scope_to_token_endpoint: false,
      client_auth_method: :basic,
      client_options: client_options(URI.parse(issuer))
    }
  end

  def self.client_options(issuer_uri)
    options = {
      identifier: ENV.fetch('SHEKEL_OIDC_CLIENT_ID'),
      secret: ENV.fetch('SHEKEL_OIDC_CLIENT_SECRET'),
      redirect_uri: ENV.fetch('SHEKEL_OIDC_REDIRECT_URI'),
      scheme: issuer_uri.scheme,
      host: issuer_uri.host,
      port: issuer_uri.port
    }
    return options if discovery?

    options.merge(
      authorization_endpoint: ENV.fetch('SHEKEL_OIDC_AUTHORIZE_URL'),
      token_endpoint: ENV.fetch('SHEKEL_OIDC_TOKEN_URL'),
      userinfo_endpoint: ENV.fetch('SHEKEL_OIDC_USERINFO_URL'),
      jwks_uri: ENV.fetch('SHEKEL_OIDC_JWKS_URL')
    )
  end
  private_class_method :client_options
end
