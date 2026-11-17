# Shekel fork: devise_token_auth mounts sign-up (POST /auth), account update
# (PUT/PATCH /auth, which sets a new password without the current one) and
# account deletion (DELETE /auth). Nothing in Chatwoot's UI calls them, but they
# are live routes; with Shekel sign-in configured they are refused, so no
# password can be planted that would work once Shekel sign-in is turned off.
# Otherwise this is devise_token_auth's controller unchanged.
class DeviseOverrides::RegistrationsController < DeviseTokenAuth::RegistrationsController
  include ShekelPasswordLoginGuard

  # The actions are devise_token_auth's, inherited.
  prepend_before_action :refuse_shekel_password_management, only: [:create, :update, :destroy] # rubocop:disable Rails/LexicallyScopedActionFilter
end
