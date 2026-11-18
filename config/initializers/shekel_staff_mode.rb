# Shekel fork: refuse to boot in production when staff mode is on
# (SHEKEL_CHATWOOT_ACCOUNT_ID set) but Shekel sign-in is not configured
# (SHEKEL_OIDC_CLIENT_ID blank). Staff mode would refuse every other way in, so
# the deploy would look healthy while nobody could sign in. See
# Shekel::OidcSettings.verify_configuration! and docs/shekel/OPERATIONS.md.
Rails.application.config.after_initialize do
  Shekel::OidcSettings.verify_configuration!
end
