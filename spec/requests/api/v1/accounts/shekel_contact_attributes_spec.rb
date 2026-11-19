require 'rails_helper'

# Shekel fork: the shekel_* contact custom attributes are set by the Shailoq
# gateway's service user only (SHEKEL_API_USER_IDS). See Shekel::LockedContactAttributes.
RSpec.describe 'Shekel locked contact attributes', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:service_user) { create(:user, account: account, role: :agent) }
  let(:contacts_url) { "/api/v1/accounts/#{account.id}/contacts" }
  let(:contact) { create(:contact, account: account, custom_attributes: { 'shekel_dealer_id' => 'd-1', 'colour' => 'red' }) }

  around do |example|
    with_modified_env(SHEKEL_API_USER_IDS: service_user.id.to_s) { example.run }
  end

  describe 'PATCH contact' do
    it 'refuses a new shekel_ key from an administrator' do
      patch "#{contacts_url}/#{contact.id}", headers: admin.create_new_auth_token, params: { custom_attributes: { shekel_tenant_id: 't-1' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(contact.reload.custom_attributes).to eq({ 'shekel_dealer_id' => 'd-1', 'colour' => 'red' })
    end

    it 'refuses a changed shekel_ value from an agent' do
      patch "#{contacts_url}/#{contact.id}", headers: agent.create_new_auth_token, params: { custom_attributes: { shekel_dealer_id: 'd-2' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(contact.reload.custom_attributes['shekel_dealer_id']).to eq('d-1')
    end

    it 'refuses a personal access token that is not a service user' do
      patch "#{contacts_url}/#{contact.id}", headers: { api_access_token: admin.access_token.token },
                                             params: { custom_attributes: { shekel_dealer_id: 'd-2' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(contact.reload.custom_attributes['shekel_dealer_id']).to eq('d-1')
    end

    it 'accepts the unchanged shekel_ values a dashboard edit sends back, and applies the other changes' do
      patch "#{contacts_url}/#{contact.id}", headers: agent.create_new_auth_token,
                                             params: { custom_attributes: { shekel_dealer_id: 'd-1', colour: 'blue' } }

      expect(response).to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'shekel_dealer_id' => 'd-1', 'colour' => 'blue' })
    end

    it 'lets the service user change and add shekel_ keys' do
      patch "#{contacts_url}/#{contact.id}", headers: { api_access_token: service_user.access_token.token },
                                             params: { custom_attributes: { shekel_dealer_id: 'd-2', shekel_tenant_id: 't-1' } }

      expect(response).to have_http_status(:success)
      expect(contact.reload.custom_attributes).to include('shekel_dealer_id' => 'd-2', 'shekel_tenant_id' => 't-1', 'colour' => 'red')
    end
  end

  describe 'POST contact' do
    it 'refuses a shekel_ key from staff and creates no contact' do
      expect do
        post contacts_url, headers: admin.create_new_auth_token, params: { name: 'New lead', custom_attributes: { shekel_dealer_id: 'd-9' } }
      end.not_to change(Contact, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'lets staff create a contact with other custom attributes' do
      post contacts_url, headers: agent.create_new_auth_token, params: { name: 'New lead', custom_attributes: { colour: 'green' } }

      expect(response).to have_http_status(:success)
    end

    it 'lets the service user create a contact with shekel_ keys' do
      post contacts_url, headers: { api_access_token: service_user.access_token.token },
                         params: { name: 'New lead', custom_attributes: { shekel_dealer_id: 'd-9' } }

      expect(response).to have_http_status(:success)
      expect(account.contacts.find_by(name: 'New lead').custom_attributes).to eq({ 'shekel_dealer_id' => 'd-9' })
    end
  end

  describe 'POST contact destroy_custom_attributes' do
    it 'refuses to delete a shekel_ key from staff and still deletes other keys' do
      post "#{contacts_url}/#{contact.id}/destroy_custom_attributes", headers: admin.create_new_auth_token,
                                                                      params: { custom_attributes: ['shekel_dealer_id'] }
      expect(response).to have_http_status(:unprocessable_entity)

      post "#{contacts_url}/#{contact.id}/destroy_custom_attributes", headers: admin.create_new_auth_token,
                                                                      params: { custom_attributes: ['colour'] }
      expect(response).to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'shekel_dealer_id' => 'd-1' })
    end

    it 'lets the service user clear the shekel_ keys and keeps the other keys' do
      post "#{contacts_url}/#{contact.id}/destroy_custom_attributes", headers: { api_access_token: service_user.access_token.token },
                                                                      params: { custom_attributes: ['shekel_dealer_id'] }

      expect(response).to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'colour' => 'red' })
    end
  end

  describe 'POST contact merge' do
    let(:base_contact) { create(:contact, account: account, custom_attributes: {}) }
    let(:merge_params) { { base_contact_id: base_contact.id, mergee_contact_id: contact.id } }

    it 'refuses a merge by staff that would copy shekel_ keys onto the base contact, and rolls it back' do
      post "/api/v1/accounts/#{account.id}/actions/contact_merge", headers: admin.create_new_auth_token, params: merge_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(base_contact.reload.custom_attributes).to eq({})
      expect(Contact.exists?(contact.id)).to be(true)
    end

    it 'lets staff merge contacts that carry no shekel_ keys' do
      plain_contact = create(:contact, account: account, custom_attributes: { 'colour' => 'red' })

      post "/api/v1/accounts/#{account.id}/actions/contact_merge", headers: admin.create_new_auth_token,
                                                                   params: { base_contact_id: base_contact.id, mergee_contact_id: plain_contact.id }

      expect(response).to have_http_status(:success)
      expect(base_contact.reload.custom_attributes).to eq({ 'colour' => 'red' })
    end
  end
end
