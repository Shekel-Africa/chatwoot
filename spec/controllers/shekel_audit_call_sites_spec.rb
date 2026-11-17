require 'rails_helper'

# Shekel fork: audit-log actions recorded synchronously in controllers, where
# the signed-in user and the request ip are at hand.
RSpec.describe 'Shekel audit log call sites', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:conversation_url) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}" }

  before { create(:inbox_member, user: agent, inbox: inbox) }

  after { Redis::Alfred.delete(Shekel::Audit.view_throttle_key(user: agent, conversation: conversation)) }

  def audit_events(action)
    Shekel::AuditEvent.where(action: action)
  end

  describe 'conversation.viewed' do
    it 'is recorded when a user opens a conversation' do
      get conversation_url, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      expect(audit_events('conversation.viewed').sole).to have_attributes(
        account_id: account.id, actor_type: 'User', actor_id: agent.id, subject_type: 'Conversation', subject_id: conversation.id,
        metadata: { 'display_id' => conversation.display_id }
      )
      expect(audit_events('conversation.viewed').sole.ip_address).to be_present
    end

    it 'is recorded when a user loads the messages' do
      get "#{conversation_url}/messages", headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      expect(audit_events('conversation.viewed').sole).to have_attributes(actor_id: agent.id, subject_id: conversation.id)
    end

    it 'is recorded at most once per user per conversation per hour' do
      headers = agent.create_new_auth_token
      get conversation_url, headers: headers, as: :json
      get "#{conversation_url}/messages", headers: headers, as: :json
      get conversation_url, headers: headers, as: :json
      expect(audit_events('conversation.viewed').count).to eq(1)

      Redis::Alfred.delete(Shekel::Audit.view_throttle_key(user: agent, conversation: conversation)) # the hour has passed
      get conversation_url, headers: headers, as: :json
      expect(audit_events('conversation.viewed').count).to eq(2)
    end

    it 'is not recorded when access is refused' do
      outsider = create(:user, account: account, role: :agent)

      get conversation_url, headers: outsider.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(audit_events('conversation.viewed')).to be_empty
    end
  end

  describe 'conversation.transcript_sent' do
    it 'is recorded without the recipient address' do
      mailer = double
      allow(ConversationReplyMailer).to receive(:with).and_return(mailer)
      allow(mailer).to receive(:conversation_transcript)

      post "#{conversation_url}/transcript", headers: agent.create_new_auth_token, params: { email: 'customer@example.test' }, as: :json

      expect(response).to have_http_status(:success)
      event = audit_events('conversation.transcript_sent').sole
      expect(event).to have_attributes(actor_id: agent.id, subject_id: conversation.id, metadata: { 'display_id' => conversation.display_id })
      expect(event.attributes.values.join(' ')).not_to include('customer@example.test')
    end
  end

  describe 'contacts.exported' do
    it 'is recorded for the contacts export endpoint' do
      post "/api/v1/accounts/#{account.id}/contacts/export", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      export = account.data_exports.sole
      expect(audit_events('contacts.exported').sole).to have_attributes(
        actor_id: admin.id, subject_type: 'DataExport', subject_id: export.id,
        metadata: { 'data_export_id' => export.id, 'data_type' => 'contacts' }
      )
    end

    it 'is recorded for the data exports endpoint' do
      post "/api/v1/accounts/#{account.id}/data_exports", headers: admin.create_new_auth_token,
                                                          params: { column_names: %w[email name], scope_name: 'All contacts' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(audit_events('contacts.exported').sole).to have_attributes(actor_id: admin.id, subject_id: account.data_exports.sole.id)
    end

    it 'is not recorded when the export is refused' do
      post "/api/v1/accounts/#{account.id}/contacts/export", headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
      expect(audit_events('contacts.exported')).to be_empty
    end
  end

  describe 'staff.signed_out' do
    it 'is recorded when a user signs out' do
      delete '/auth/sign_out', headers: agent.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(audit_events('staff.signed_out').sole).to have_attributes(
        account_id: account.id, actor_type: 'User', actor_id: agent.id, subject_type: 'User', subject_id: agent.id
      )
    end

    it 'is not recorded for a sign-out without a valid session' do
      delete '/auth/sign_out'

      expect(audit_events('staff.signed_out')).to be_empty
    end
  end
end
