# Shekel fork: finishes a sign-in through authentication-api's admin realm.
#
# Matches the verified email to an existing Chatwoot agent and signs them in
# through upstream's SSO-token path, the same one Google sign-in uses.
# There is no auto-provisioning: an email with no agent is refused.
#
# The strategy has already checked the ID token's signature (RS256), issuer,
# audience and nonce. The `realm` claim is checked again here so that a client
# pointed at the customer (user) realm by mistake can never sign a dealer in as
# staff.
#
# The check has to happen in `redirect_callbacks`: devise_token_auth copies the
# auth hash into the session there *without* `extra` (where the ID-token claims
# live) before redirecting to `omniauth_success`. A one-shot session flag carries
# the result across that redirect, so `omniauth_success` cannot be reached for
# this provider without passing the check.
module ShekelOidcSignIn
  ADMIN_REALM = 'admin'.freeze
  REALM_VERIFIED_KEY = 'shekel.oidc.admin_realm_verified'.freeze

  # First callback hop (/omniauth/shekel/callback), where the full auth hash is
  # still available.
  def redirect_callbacks
    return super unless shekel_oidc_callback?

    session.delete(REALM_VERIFIED_KEY)
    return redirect_to login_page_url(error: 'no-account-found') unless shekel_admin_realm?(request.env['omniauth.auth'])

    session[REALM_VERIFIED_KEY] = true
    super
  end

  private

  def shekel_oidc_callback?
    params[:provider] == Shekel::OidcSettings::PROVIDER
  end

  # Second hop (/auth/shekel/callback), called from omniauth_success.
  def sign_in_shekel_staff
    return redirect_to login_page_url(error: 'no-account-found') unless session.delete(REALM_VERIFIED_KEY)

    get_resource_from_auth_hash
    return redirect_to login_page_url(error: 'no-account-found') if @resource.blank?

    sign_in_user
  end

  def shekel_admin_realm?(omniauth_auth)
    omniauth_auth&.dig('extra', 'raw_info', 'realm') == ADMIN_REALM
  end
end
