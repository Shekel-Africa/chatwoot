require 'rails_helper'

# Shekel fork: in staff mode, staff sign in through Shekel only, so every
# password surface (sign-in, reset, profile change) is refused.
RSpec.describe 'Shekel password login guard', type: :request do
  let(:account) { create(:account) }
  let!(:user) { create(:user, password: 'Password1!', account: account) }
  let(:staff_mode) { { SHEKEL_CHATWOOT_ACCOUNT_ID: account.id.to_s, SHEKEL_OIDC_CLIENT_ID: 'chatwoot-test-client' } }
  let(:refusal) { 'Sign in with Shekel instead.' }

  def expect_refused(status)
    expect(response).to have_http_status(status)
    expect(response.parsed_body['errors']).to eq([refusal])
  end

  it 'password_sign_in_returns_401_in_staff_mode' do
    with_modified_env(**staff_mode) do
      post new_user_session_url, params: { email: user.email, password: 'Password1!' }, as: :json

      expect_refused(:unauthorized)
      expect(response.headers['access-token']).to be_blank
    end
  end

  # Fails closed: losing the OIDC settings does not bring password sign-in back.
  it 'still refuses password sign-in and reset in staff mode with Shekel sign-in not configured' do
    with_modified_env(**staff_mode, SHEKEL_OIDC_CLIENT_ID: nil) do
      post new_user_session_url, params: { email: user.email, password: 'Password1!' }, as: :json
      expect_refused(:unauthorized)

      post user_password_path, params: { email: user.email }, as: :json
      expect_refused(:forbidden)
    end
  end

  it 'refuses password sign-in sent as headers too' do
    with_modified_env(**staff_mode) do
      post new_user_session_url, headers: { email: user.email, password: 'Password1!' }, as: :json

      expect_refused(:unauthorized)
    end
  end

  it 'refuses a sign-in with an sso_auth_token that is not valid' do
    with_modified_env(**staff_mode) do
      post new_user_session_url, params: { email: user.email, password: 'Password1!', sso_auth_token: SecureRandom.hex(32) }, as: :json

      expect_refused(:unauthorized)
    end
  end

  it 'sso_auth_token_sign_in_still_works' do
    with_modified_env(**staff_mode) do
      post new_user_session_url, params: { email: user.email, sso_auth_token: user.generate_sso_auth_token }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('data', 'email')).to eq(user.email)
    end
  end

  it 'password_reset_request_and_update_are_refused' do
    with_modified_env(**staff_mode) do
      expect do
        post user_password_path, params: { email: user.email }, as: :json
      end.not_to(change { user.reload.reset_password_token })
      expect_refused(:forbidden)

      token = user.send(:set_reset_password_token)
      put user_password_path, params: { reset_password_token: token, password: 'Changed1!x', password_confirmation: 'Changed1!x' }, as: :json
      expect_refused(:forbidden)
      expect(user.reload.valid_password?('Password1!')).to be(true)
    end
  end

  it 'profile_password_change_is_refused' do
    with_modified_env(**staff_mode) do
      put '/api/v1/profile',
          params: { profile: { current_password: 'Password1!', password: 'Changed1!x', password_confirmation: 'Changed1!x' } },
          headers: user.create_new_auth_token,
          as: :json

      expect_refused(:forbidden)
      expect(user.reload.valid_password?('Password1!')).to be(true)
    end
  end

  it 'still lets a profile be updated without a password' do
    with_modified_env(**staff_mode) do
      put '/api/v1/profile', params: { profile: { name: 'Renamed' } }, headers: user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(user.reload.name).to eq('Renamed')
    end
  end

  it 'registrations_password_update_is_refused' do
    with_modified_env(**staff_mode) do
      put '/auth', params: { password: 'Changed1!x', password_confirmation: 'Changed1!x' }, headers: user.create_new_auth_token, as: :json

      expect_refused(:forbidden)
      expect(user.reload.valid_password?('Password1!')).to be(true)
    end
  end

  it 'registrations_sign_up_and_delete_are_refused' do
    with_modified_env(**staff_mode) do
      expect do
        post '/auth', params: { email: 'new@shekel.test', password: 'Changed1!x', password_confirmation: 'Changed1!x' }, as: :json
      end.not_to change(User, :count)
      expect_refused(:forbidden)

      delete '/auth', headers: user.create_new_auth_token, as: :json
      expect_refused(:forbidden)
      expect(User.exists?(user.id)).to be(true)
    end
  end

  it 'leaves the registrations routes as upstream when staff mode is off' do
    with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil) do
      # Upstream lets a session token set a new password without the current one.
      put '/auth', params: { password: 'Changed1!x', password_confirmation: 'Changed1!x' }, headers: user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(user.reload.valid_password?('Changed1!x')).to be(true)
    end
  end

  it 'api_access_token_requests_are_unaffected' do
    with_modified_env(**staff_mode) do
      get '/api/v1/profile', headers: { api_access_token: user.access_token.token }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['email']).to eq(user.email)
    end
  end

  it 'password_sign_in_still_works_when_staff_mode_is_off' do
    with_modified_env(SHEKEL_CHATWOOT_ACCOUNT_ID: nil) do
      post new_user_session_url, params: { email: user.email, password: 'Password1!' }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.headers['access-token']).to be_present
    end
  end
end
