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
# staff. The granted scope must include `customer_comms.access`: the IdP refuses
# without it only when the client lists it as required, so it is checked here
# too, or any admin-realm admin would be provisioned.
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
    return redirect_to login_page_url(error: 'no-account-found') unless shekel_staff_sign_in_allowed?(auth)
    return redirect_to login_page_url(error: 'shekel-misconfigured') if shekel_staff_account.blank?

    session[REALM_VERIFIED_KEY] = { 'tenants' => shekel_tenant_ids(auth), 'admin' => shekel_comms_admin?(auth) }
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

    account = shekel_staff_account
    return redirect_to login_page_url(error: 'shekel-misconfigured') if account.blank?

    @resource = Shekel::StaffSync.new(
      account: account,
      email: auth_hash.dig('info', 'email'),
      name: auth_hash.dig('info', 'name'),
      tenant_ids: verified['tenants'],
      admin: verified['admin'] == true
    ).call

    sign_in_user
    Shekel::Audit.record(action: 'staff.signed_in', actor: @resource, subject: @resource, account: account,
                         metadata: { provider: Shekel::OidcSettings::PROVIDER }, ip: request.remote_ip)
  end

  def shekel_staff_sign_in_allowed?(omniauth_auth)
    shekel_admin_realm?(omniauth_auth) &&
      shekel_granted_scopes(omniauth_auth).include?(Shekel::OidcSettings::ACCESS_SCOPE) &&
      omniauth_auth.dig('info', 'email').present?
  end

  def shekel_admin_realm?(omniauth_auth)
    omniauth_auth&.dig('extra', 'raw_info', 'realm') == ADMIN_REALM
  end

  # The account staff are provisioned into, or nil (logged) when
  # SHEKEL_CHATWOOT_ACCOUNT_ID is unset or names no account.
  def shekel_staff_account
    account = Account.find_by(id: Shekel::OidcSettings.account_id)
    Rails.logger.error('Shekel OIDC: SHEKEL_CHATWOOT_ACCOUNT_ID names no account') if account.nil?
    account
  rescue KeyError, ArgumentError
    Rails.logger.error('Shekel OIDC: SHEKEL_CHATWOOT_ACCOUNT_ID is not set or not an integer')
    nil
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

  def shekel_comms_admin?(omniauth_auth)
    shekel_granted_scopes(omniauth_auth).include?(Shekel::OidcSettings::ADMIN_SCOPE)
  end

  # The token response's `scope` (space-separated), exposed by the strategy as credentials.scope.
  def shekel_granted_scopes(omniauth_auth)
    omniauth_auth.dig('credentials', 'scope').to_s.split
  end
end
