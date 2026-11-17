# Shekel fork: in staff mode (Shekel::OidcSettings.staff_mode?), staff sign in
# through Shekel only. Password sign-in, password reset and the profile password
# change are refused, and so is an SSO token from any other provider (Google,
# platform SSO links, impersonation): only the SSO token that finishes a Shekel
# sign-in (Shekel::SsoTokens) is accepted. Staff mode keys on SHEKEL_CHATWOOT_ACCOUNT_ID, not on the OIDC
# client id, so losing the OIDC settings does not bring passwords back.
#
# Same shape as enterprise's SamlAuthenticationHelper#saml_user_attempting_password_auth?.
module ShekelPasswordLoginGuard
  extend ActiveSupport::Concern

  private

  def shekel_password_auth_attempt?(email, sso_auth_token: nil)
    return false unless Shekel::OidcSettings.password_login_disabled?
    return false if email.present? && Shekel::SsoTokens.shekel?(User.from_email(email), sso_auth_token)

    true
  end

  # POST /auth/sign_in
  def refuse_shekel_password_sign_in
    email = params[:email].to_s.strip.downcase.presence
    render_shekel_password_login_disabled(:unauthorized) if shekel_password_auth_attempt?(email, sso_auth_token: params[:sso_auth_token])
  end

  # POST and PUT /auth/password; POST, PUT/PATCH and DELETE /auth (registrations)
  def refuse_shekel_password_management
    render_shekel_password_login_disabled(:forbidden) if Shekel::OidcSettings.password_login_disabled?
  end

  # PUT /api/v1/profile with a new password
  def refuse_shekel_password_change
    return unless Shekel::OidcSettings.password_login_disabled?
    return if params.dig(:profile, :password).blank?

    render_shekel_password_login_disabled(:forbidden)
  end

  def render_shekel_password_login_disabled(status)
    message = I18n.t('messages.shekel_password_login_disabled')
    render json: { success: false, message: message, errors: [message] }, status: status
  end
end
