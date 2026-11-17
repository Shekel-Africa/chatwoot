require 'csv'

# Shekel fork: CSV export of the account's audit log, administrators only.
#
#   GET /api/v1/accounts/:account_id/shekel/audit_events?from=2026-11-01&to=2026-11-17
#
# `from` and `to` are ISO dates, inclusive; the default is the last 30 days and
# a range may span at most 366 days. Rows stream oldest first in batches, and
# the download is itself recorded as `audit.exported`.
class Api::V1::Accounts::Shekel::AuditEventsController < Api::V1::Accounts::BaseController
  DEFAULT_RANGE = 30.days
  MAX_RANGE_DAYS = 366
  COLUMNS = %w[id created_at account_id actor_type actor_id action subject_type subject_id ip_address metadata].freeze

  before_action :check_admin_authorization?
  before_action :set_range

  def index
    shekel_audit('audit.exported', subject: nil, metadata: { from: @from.iso8601, to: @to.iso8601 })

    headers['Content-Type'] = 'text/csv; charset=utf-8'
    headers['Content-Disposition'] = %(attachment; filename="audit-log-#{@from.iso8601}-to-#{@to.iso8601}.csv")
    headers['Cache-Control'] = 'no-store'
    headers['X-Accel-Buffering'] = 'no'
    headers.delete('Content-Length')
    self.response_body = csv_lines
  end

  private

  def set_range
    @to = params[:to].present? ? Date.iso8601(params[:to]) : Time.zone.today
    @from = params[:from].present? ? Date.iso8601(params[:from]) : @to - DEFAULT_RANGE
    return if @from <= @to && (@to - @from).to_i <= MAX_RANGE_DAYS

    render json: { error: "from must not be after to, and the range may span at most #{MAX_RANGE_DAYS} days" }, status: :unprocessable_entity
  rescue Date::Error
    render json: { error: 'from and to must be ISO 8601 dates (YYYY-MM-DD)' }, status: :unprocessable_entity
  end

  def csv_lines
    scope = ::Shekel::AuditEvent.where(account_id: Current.account.id,
                                       created_at: @from.in_time_zone.beginning_of_day..@to.in_time_zone.end_of_day)
    Enumerator.new do |lines|
      lines << CSV.generate_line(COLUMNS)
      scope.find_each { |event| lines << CSV.generate_line(row(event)) }
    end
  end

  def row(event)
    [event.id, event.created_at.utc.iso8601, event.account_id, event.actor_type, event.actor_id, event.action,
     event.subject_type, event.subject_id, event.ip_address&.to_s, event.metadata.to_json]
  end
end
