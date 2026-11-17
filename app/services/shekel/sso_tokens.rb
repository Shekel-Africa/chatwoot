# Shekel fork: marks the one-time SSO tokens that finish a Shekel sign-in.
#
# Upstream's SSO token (SsoAuthenticatable) is also issued by Google sign-in,
# the platform API's SSO link and super-admin impersonation. In staff mode the
# password guard (ShekelPasswordLoginGuard) accepts only tokens issued here, by
# ShekelOidcSignIn after the admin-realm checks, so no other path signs staff in.
# The mark lives in Redis next to the token and expires with it.
module Shekel::SsoTokens
  TTL = 5.minutes

  module_function

  def issue(user)
    token = user.generate_sso_auth_token
    ::Redis::Alfred.setex(key(user, token), '1', TTL)
    token
  end

  def shekel?(user, token)
    return false if user.blank? || token.blank?

    user.valid_sso_auth_token?(token) && ::Redis::Alfred.get(key(user, token)).present?
  end

  def key(user, token)
    "SHEKEL::SSO_AUTH_TOKEN::#{user.id}::#{Digest::SHA256.hexdigest(token.to_s)}"
  end
end
