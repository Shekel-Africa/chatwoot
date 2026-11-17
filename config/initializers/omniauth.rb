# OmniAuth configuration
# Sets the full host URL for callbacks and proper redirect handling
OmniAuth.config.full_host = ENV.fetch('FRONTEND_URL', 'http://localhost:3000')

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2, ENV.fetch('GOOGLE_OAUTH_CLIENT_ID', nil), ENV.fetch('GOOGLE_OAUTH_CLIENT_SECRET', nil), {
    provider_ignores_state: true
  }

  # Shekel fork: staff sign-in through authentication-api's admin realm.
  # Settings come from SHEKEL_OIDC_* at request time; see Shekel::OidcSettings.
  provider :openid_connect, {
    name: :shekel,
    setup: ->(env) { Shekel::OidcSettings.apply(env['omniauth.strategy']) }
  }
end
