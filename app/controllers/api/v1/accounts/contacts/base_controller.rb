class Api::V1::Accounts::Contacts::BaseController < Api::V1::Accounts::BaseController
  before_action :ensure_contact

  private

  def ensure_contact
    # Shekel fork: another team's contact reads as not found.
    @contact = Shekel::ContactVisibility.contacts(user: Current.user, account: Current.account).find(params[:contact_id])
  end
end
