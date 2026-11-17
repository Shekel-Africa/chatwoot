# Shekel fork: staff sign-in through authentication-api's admin realm (OIDC).
#
# The `shekel` OmniAuth provider is always mounted, like upstream's
# google_oauth2 one, and reads its settings from ENV on each request through
# OmniAuth's setup phase. It is offered on the login page only when
# SHEKEL_OIDC_CLIENT_ID is set. Required settings are read with ENV.fetch so a
# half-configured provider fails loudly instead of redirecting somewhere wrong.
#
# See docs/shekel/LOCAL_OIDC_LOGIN.md for the variables and the client to register.
class Shekel::OidcSettings
  PROVIDER = 'shekel'.freeze
  SCOPES = %i[openid email profile].freeze

  def self.enabled?
    ENV.fetch('SHEKEL_OIDC_CLIENT_ID', '').present?
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
