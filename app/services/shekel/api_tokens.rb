# Shekel fork: personal API access tokens in staff mode.
#
# Every user has an AccessToken that works on the whole API with no expiry, so
# a staff member could keep using it after their 12-hour session ends, after
# Shekel removes them and after their teams change. In staff mode
# (Shekel::OidcSettings.staff_mode?) a token owned by a User is refused unless
# the user id is listed in SHEKEL_API_USER_IDS (comma-separated; the Shailoq
# gateway's administrator service user, which deletes contacts on unlink).
# Agent bot tokens are unaffected. The token is also left out of the user JSON
# for everyone not listed, and Shekel::StaffSync rotates it on every sign-in.
#
# Called from AccessTokenAuthHelper#authenticate_access_token!,
# app/views/api/v1/models/_user.json.jbuilder and Shekel::StaffSync.
module Shekel::ApiTokens
  module_function

  def refused?(access_token)
    Shekel::OidcSettings.staff_mode? && access_token.owner_type == 'User' && !allowed_user_id?(access_token.owner_id)
  end

  # Whether the user JSON may show the user's own token.
  def exposed?(user)
    !Shekel::OidcSettings.staff_mode? || allowed_user_id?(user.id)
  end

  def allowed_user_id?(user_id)
    allowed_user_ids.include?(user_id)
  end

  def allowed_user_ids
    ENV.fetch('SHEKEL_API_USER_IDS', '').split(',').filter_map { |id| Integer(id.strip, 10, exception: false) }
  end
end
