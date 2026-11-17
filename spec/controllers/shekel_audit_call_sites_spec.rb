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

  describe 'csat.exported' do
    let(:csat_url) { "/api/v1/accounts/#{account.id}/csat_survey_responses/download" }

    it 'is recorded with the range and filters only' do
      get csat_url, params: { since: '1762300800', until: '1763337600', inbox_id: inbox.id, rating: [1, 2] },
                    headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(audit_events('csat.exported').sole).to have_attributes(
        account_id: account.id, actor_type: 'User', actor_id: admin.id, subject_type: nil,
        metadata: { 'since' => 1_762_300_800, 'until' => 1_763_337_600, 'inbox_id' => inbox.id, 'rating' => [1, 2] }
      )
    end

    it 'is not recorded when the download is refused' do
      get csat_url, headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
      expect(audit_events('csat.exported')).to be_empty
    end
  end

  describe 'data_export.downloaded' do
    let(:export) do
      account.data_exports.create!(name: 'Contacts', export_options: { column_names: ['email'] }, initiated_by: admin, status: :completed)
    end

    it 'is recorded when the file URL is handed out' do
      export.export_file.attach(io: StringIO.new("email\n"), filename: 'contacts.csv', content_type: 'text/csv')

      get "/api/v1/accounts/#{account.id}/data_exports/#{export.id}/download", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(audit_events('data_export.downloaded').sole).to have_attributes(
        actor_id: admin.id, subject_type: 'DataExport', subject_id: export.id,
        metadata: { 'data_export_id' => export.id, 'data_type' => 'contacts' }
      )
    end

    it 'is not recorded when there is no file' do
      get "/api/v1/accounts/#{account.id}/data_exports/#{export.id}/download", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:not_found)
      expect(audit_events('data_export.downloaded')).to be_empty
    end
  end

  describe 'data_import.downloaded' do
    let(:data_import) { create(:data_import, :intercom, account: account, initiated_by: admin) }
    let(:import_url) { "/api/v1/accounts/#{account.id}/data_imports/#{data_import.id}" }

    before { account.enable_features!('data_import') }

    def expect_download_recorded(kind)
      expect(response).to have_http_status(:ok)
      expect(audit_events('data_import.downloaded').sole).to have_attributes(
        account_id: account.id, actor_type: 'User', actor_id: admin.id, subject_type: 'DataImport', subject_id: data_import.id,
        metadata: { 'data_import_id' => data_import.id, 'kind' => kind }
      )
    end

    it 'is recorded for the error log' do
      get "#{import_url}/error_logs.csv", headers: admin.create_new_auth_token

      expect_download_recorded('error_logs')
    end

    it 'is recorded for the skip log' do
      get "#{import_url}/skip_logs.csv", headers: admin.create_new_auth_token

      expect_download_recorded('skip_logs')
    end

    it 'is recorded for the rejected rows file' do
      data_import.failed_records.attach(io: StringIO.new("email\n"), filename: 'rejected.csv', content_type: 'text/csv')

      get "#{import_url}/rejected_rows", headers: admin.create_new_auth_token

      expect_download_recorded('rejected_rows')
    end

    it 'is not recorded when there are no rejected rows' do
      get "#{import_url}/rejected_rows", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:not_found)
      expect(audit_events('data_import.downloaded')).to be_empty
    end

    it 'is not recorded when the download is refused' do
      get "#{import_url}/error_logs.csv", headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
      expect(audit_events('data_import.downloaded')).to be_empty
    end
  end

  describe 'agent bot actions' do
    let(:agent_bot) { create(:agent_bot, account: account) }
    let(:bot_headers) { { api_access_token: agent_bot.access_token.token } }

    before { create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot) }

    it 'records the AgentBot as the actor of a bot-token toggle_status' do
      post "#{conversation_url}/toggle_status", headers: bot_headers, params: { status: 'resolved' }, as: :json
      expect(response).to have_http_status(:success)

      perform_enqueued_jobs(only: EventDispatcherJob)

      expect(audit_events('conversation.resolved').sole).to have_attributes(actor_type: 'AgentBot', actor_id: agent_bot.id)
    end

    it 'records the AgentBot as the actor of a bot-token assignment' do
      post "#{conversation_url}/assignments", headers: bot_headers, params: { assignee_id: agent.id }, as: :json
      expect(response).to have_http_status(:success)

      perform_enqueued_jobs(only: EventDispatcherJob)

      expect(audit_events('conversation.assigned').sole).to have_attributes(actor_type: 'AgentBot', actor_id: agent_bot.id,
                                                                            metadata: include('to_assignee_id' => agent.id))
    end

    it 'throttles a bot view separately from a user with the same id' do
      expect(Shekel::Audit.view_throttle_key(user: agent_bot, conversation: conversation))
        .not_to eq(Shekel::Audit.view_throttle_key(user: build_stubbed(:user, id: agent_bot.id), conversation: conversation))
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
