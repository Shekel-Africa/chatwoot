require 'rails_helper'
require 'csv'

# Shekel fork: CSV export of the audit log.
RSpec.describe 'Shekel audit log export', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account) }
  let(:url) { "/api/v1/accounts/#{account.id}/shekel/audit_events" }

  def record(action, at:, target_account: account)
    travel_to(at) { Shekel::Audit.record(action: action, actor: agent, subject: conversation, account: target_account) }
  end

  def csv_rows
    CSV.parse(response.body, headers: true)
  end

  it 'export_is_administrators_only_and_is_itself_audited' do
    get url, headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
    expect(Shekel::AuditEvent.where(action: 'audit.exported')).to be_empty

    get url, params: { from: '2026-11-01', to: '2026-11-17' }, headers: admin.create_new_auth_token,
             env: { 'REMOTE_ADDR' => '198.51.100.4' }

    expect(response).to have_http_status(:ok)
    expect(Shekel::AuditEvent.where(action: 'audit.exported').sole).to have_attributes(
      account_id: account.id, actor_type: 'User', actor_id: admin.id, subject_type: nil, subject_id: nil,
      metadata: { 'from' => '2026-11-01', 'to' => '2026-11-17' }
    )
    expect(Shekel::AuditEvent.where(action: 'audit.exported').sole.ip_address.to_s).to eq('198.51.100.4')
  end

  it 'returns the account events in the range as CSV, oldest first' do
    # a past range, so that this download's own audit.exported row falls outside it
    before_range = record('conversation.viewed', at: Time.zone.parse('2026-09-30 23:59'))
    first = record('conversation.viewed', at: Time.zone.parse('2026-10-01 00:00'))
    last = record('conversation.resolved', at: Time.zone.parse('2026-10-17 23:59'))
    record('conversation.viewed', at: Time.zone.parse('2026-10-05 12:00'), target_account: create(:account))

    get url, params: { from: '2026-10-01', to: '2026-10-17' }, headers: admin.create_new_auth_token

    expect(response.media_type).to eq('text/csv')
    expect(response.headers['Content-Disposition']).to include('attachment', 'audit-log-2026-10-01-to-2026-10-17.csv')
    rows = csv_rows
    expect(rows.headers).to eq(%w[id created_at account_id actor_type actor_id action subject_type subject_id ip_address metadata])
    expect(rows.pluck('id').map(&:to_i)).to eq([first.id, last.id])
    expect(rows.pluck('id').map(&:to_i)).not_to include(before_range.id)
    expect(rows.first.to_h).to include('actor_type' => 'User', 'actor_id' => agent.id.to_s, 'action' => 'conversation.viewed',
                                       'subject_type' => 'Conversation', 'subject_id' => conversation.id.to_s)
  end

  it 'defaults to the last 30 days' do
    travel_to(Time.zone.parse('2026-11-17 10:00')) do
      get url, headers: admin.create_new_auth_token
    end

    expect(response).to have_http_status(:ok)
    expect(Shekel::AuditEvent.where(action: 'audit.exported').sole.metadata).to eq('from' => '2026-10-18', 'to' => '2026-11-17')
  end

  it 'rejects an invalid or oversized range' do
    get url, params: { from: 'yesterday' }, headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    get url, params: { from: '2026-11-17', to: '2026-11-01' }, headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    get url, params: { from: '2025-01-01', to: '2026-11-17' }, headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    expect(Shekel::AuditEvent.where(action: 'audit.exported')).to be_empty
  end
end
