# Shekel fork: an agent bot (or the Shailoq service user) reacts to an incoming WhatsApp message, e.g. to show it was
# received. Opt-in on the caller's side; see Shekel::WhatsappSeenSignal.
class Api::V1::Accounts::Conversations::ReactionsController < Api::V1::Accounts::Conversations::BaseController
  def create
    message = @conversation.messages.find_by(id: params[:message_id])
    problem = Shekel::WhatsappSeenSignal.reaction_problem(@conversation, message, params[:emoji])
    return render json: { error: problem }, status: :unprocessable_entity if problem

    Shekel::WhatsappSeenSignalJob.perform_later(@conversation.id, message.id, params[:emoji])
    head :accepted
  end
end
