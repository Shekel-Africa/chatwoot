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
  # still available. In staff mode every other provider is refused here and in
  # omniauth_success.
  def redirect_callbacks
    return redirect_to login_page_url(error: 'no-account-found') if shekel_other_provider_refused?
    return super unless shekel_oidc_callback?

    session.delete(REALM_VERIFIED_KEY)
    auth = request.env['omniauth.auth']
    return redirect_to login_page_url(error: 'no-account-found') unless shekel_staff_sign_in_allowed?(auth)
    return redirect_to login_page_url(error: 'shekel-misconfigured') if shekel_staff_account.blank?

    session[REALM_VERIFIED_KEY] = shekel_verified_claims(auth)
    super
    # The second hop needs only `info`; dropping the tokens keeps the cookie
    # session small now that the ID token carries the tenants claim.
    session['dta.omniauth.auth'] = session['dta.omniauth.auth']&.except('credentials')
  end

  private

  def shekel_oidc_callback?
    params[:provider] == Shekel::OidcSettings::PROVIDER
  end

  # Staff sign in through Shekel only: Google (and any other provider) would
  # skip the realm, scope and team checks.
  def shekel_other_provider_refused?
    Shekel::OidcSettings.staff_mode? && !shekel_oidc_callback?
  end

  # Second hop (/auth/shekel/callback), called from omniauth_success.
  def sign_in_shekel_staff
    verified = session.delete(REALM_VERIFIED_KEY)
    return redirect_to login_page_url(error: 'no-account-found') unless verified.is_a?(Hash)

    account = shekel_staff_account
    return redirect_to login_page_url(error: 'shekel-misconfigured') if account.blank?

    @resource = shekel_staff_sync(account, verified)

    # A marked token: in staff mode the password guard accepts no other SSO token.
    redirect_to login_page_url(email: ERB::Util.url_encode(@resource.email), sso_auth_token: Shekel::SsoTokens.issue(@resource))
    Shekel::Audit.record(action: 'staff.signed_in', actor: @resource, subject: @resource, account: account,
                         metadata: { provider: Shekel::OidcSettings::PROVIDER }, ip: request.remote_ip)
  end

  def shekel_staff_sync(account, verified)
    Shekel::StaffSync.new(
      account: account,
      identity: { sub: verified['sub'], email: auth_hash.dig('info', 'email'), name: auth_hash.dig('info', 'name') },
      tenant_ids: verified['tenants_claim'] ? verified['tenants'] : nil,
      admin: verified['admin'] == true
    ).call
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

  # What the second hop needs, carried in the cookie session. Only the tenant
  # ids mapped to a team of the staff account are kept (an `all_tenants`
  # administrator's claim lists every tenant and would overflow the 4 KB
  # cookie); `tenants_claim` records whether the claim was there at all.
  def shekel_verified_claims(omniauth_auth)
    tenant_ids = shekel_tenant_ids(omniauth_auth)
    mapped = tenant_ids && Shekel::TenantTeam.where(account: shekel_staff_account, tenant_id: tenant_ids).distinct.pluck(:tenant_id)

    {
      'sub' => (omniauth_auth.dig('extra', 'raw_info', 'sub').presence || omniauth_auth['uid']).to_s.presence,
      'tenants_claim' => !tenant_ids.nil?,
      'tenants' => mapped || [],
      'admin' => shekel_comms_admin?(omniauth_auth)
    }
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
