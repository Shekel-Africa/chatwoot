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

  def shekel_audit_export(data_export)
    shekel_audit('contacts.exported', subject: data_export,
                                      metadata: { data_export_id: data_export.id, data_type: data_export.data_type })
  end
end
