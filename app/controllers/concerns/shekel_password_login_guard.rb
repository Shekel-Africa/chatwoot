# Shekel fork: with Shekel sign-in configured, staff sign in through Shekel
# only. Password sign-in, password reset and the profile password change are
# refused; the SSO-token sign-in that finishes a Shekel (or Google) sign-in and
# API access tokens are unaffected.
#
# Same shape as enterprise's SamlAuthenticationHelper#saml_user_attempting_password_auth?.
module ShekelPasswordLoginGuard
  extend ActiveSupport::Concern

  private

  def shekel_password_auth_attempt?(email, sso_auth_token: nil)
    return false unless Shekel::OidcSettings.password_login_disabled?
    return false if sso_auth_token.present? && email.present? && User.from_email(email)&.valid_sso_auth_token?(sso_auth_token)

    true
  end

  # POST /auth/sign_in
  def refuse_shekel_password_sign_in
    email = params[:email].to_s.strip.downcase.presence
    render_shekel_password_login_disabled(:unauthorized) if shekel_password_auth_attempt?(email, sso_auth_token: params[:sso_auth_token])
  end

  # POST and PUT /auth/password
  def refuse_shekel_password_reset
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
