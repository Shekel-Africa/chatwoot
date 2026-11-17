# Shekel fork: finishes a sign-in through authentication-api's admin realm.
#
# Signs the staff member in through upstream's SSO-token path, the same one
# Google sign-in uses, after provisioning and syncing them with
# Shekel::StaffSync: an unknown email gets a user, the role follows the CRM
# admin grant, and team membership follows the tenants claim.
#
# The strategy has already checked the ID token's signature (RS256), issuer,
# audience and nonce. The `realm` claim is checked again here so that a client
# pointed at the customer (user) realm by mistake can never sign a dealer in as
# staff. authentication-api refuses the sign-in outright without the
# `customer_comms.access` scope, so reaching this callback implies it.
#
# The check has to happen in `redirect_callbacks`: devise_token_auth copies the
# auth hash into the session there *without* `extra` (where the ID-token claims
# live) before redirecting to `omniauth_success`. A one-shot session hash
# carries the result of the check and what the sync needs across that redirect,
# so `omniauth_success` cannot be reached for this provider without passing it.
module ShekelOidcSignIn
  ADMIN_REALM = 'admin'.freeze
  REALM_VERIFIED_KEY = 'shekel.oidc.admin_realm_verified'.freeze

  # First callback hop (/omniauth/shekel/callback), where the full auth hash is
  # still available.
  def redirect_callbacks
    return super unless shekel_oidc_callback?

    session.delete(REALM_VERIFIED_KEY)
    auth = request.env['omniauth.auth']
    return redirect_to login_page_url(error: 'no-account-found') unless shekel_admin_realm?(auth)

    session[REALM_VERIFIED_KEY] = { 'tenants' => shekel_tenant_ids(auth), 'admin' => shekel_crm_admin?(auth) }
    super
    # The second hop needs only `info`; dropping the tokens keeps the cookie
    # session small now that the ID token carries the tenants claim.
    session['dta.omniauth.auth'] = session['dta.omniauth.auth']&.except('credentials')
  end

  private

  def shekel_oidc_callback?
    params[:provider] == Shekel::OidcSettings::PROVIDER
  end

  # Second hop (/auth/shekel/callback), called from omniauth_success.
  def sign_in_shekel_staff
    verified = session.delete(REALM_VERIFIED_KEY)
    return redirect_to login_page_url(error: 'no-account-found') unless verified.is_a?(Hash)

    @resource = Shekel::StaffSync.new(
      account: Account.find(Shekel::OidcSettings.account_id),
      email: auth_hash.dig('info', 'email'),
      name: auth_hash.dig('info', 'name'),
      tenant_ids: verified['tenants'],
      admin: verified['admin'] == true
    ).call

    sign_in_user
  end

  def shekel_admin_realm?(omniauth_auth)
    omniauth_auth&.dig('extra', 'raw_info', 'realm') == ADMIN_REALM
  end

  # Tenant ids from the `tenants` claim, or nil when the claim is absent (an
  # IdP that predates it), so the sync leaves team membership alone.
  def shekel_tenant_ids(omniauth_auth)
    tenants = omniauth_auth.dig('extra', 'raw_info', 'tenants')
    if tenants.nil?
      Rails.logger.warn('Shekel OIDC: tenants claim missing from the admin-realm sign-in; team membership not synced')
      return
    end

    Array(tenants).filter_map { |tenant| tenant.is_a?(Hash) ? tenant['id'].to_s.downcase.presence : nil }
  end

  def shekel_crm_admin?(omniauth_auth)
    omniauth_auth.dig('credentials', 'scope').to_s.split.include?(Shekel::OidcSettings::ADMIN_SCOPE)
  end
end
