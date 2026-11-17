# Shekel fork: records audit-log actions from controllers, where the signed-in
# user and the request ip are at hand. See Shekel::Audit and
# docs/shekel/AUDIT_LOG.md.
module ShekelAuditTrail
  private

  def shekel_audit(action, subject:, metadata: {}, actor: Current.user, account: Current.account)
    Shekel::Audit.record(action: action, actor: actor, subject: subject, account: account, metadata: metadata, ip: request.remote_ip)
  end

  def shekel_audit_view(conversation)
    Shekel::Audit.record_view(user: Current.user, conversation: conversation, ip: request.remote_ip)
  end

  def shekel_audit_export(data_export, action: 'contacts.exported')
    shekel_audit(action, subject: data_export, metadata: { data_export_id: data_export.id, data_type: data_export.data_type })
  end

  # csat.exported: the range and filters of the CSV, as ids and epoch seconds only.
  def shekel_audit_csat_export
    filters = {
      since: shekel_integer(params[:since]), until: shekel_integer(params[:until]),
      user_ids: shekel_integers(params[:user_ids]), inbox_id: shekel_integer(params[:inbox_id]),
      team_id: shekel_integer(params[:team_id]), rating: shekel_integers(params[:rating])
    }
    shekel_audit('csat.exported', subject: nil, metadata: filters.compact)
  end

  def shekel_integer(value)
    Integer(value.to_s, 10, exception: false)
  end

  def shekel_integers(values)
    return if values.blank?

    Array(values).filter_map { |value| shekel_integer(value) }
  end
end
