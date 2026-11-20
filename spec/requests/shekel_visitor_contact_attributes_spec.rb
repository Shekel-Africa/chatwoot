require 'rails_helper'

# Shekel fork: a website visitor or Public API client must not set the
# shekel_* contact attributes. See Shekel::LockedContactAttributes.
RSpec.describe 'Shekel locked contact attributes for visitors', type: :request do
  let(:account) { create(:account) }

  describe 'website widget' do
    let(:web_widget) { create(:channel_widget, account: account) }
    let(:contact) { create(:contact, account: account, custom_attributes: { 'colour' => 'red' }) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: web_widget.inbox) }
    let(:token) { Widget::TokenService.new(payload: { source_id: contact_inbox.source_id, inbox_id: web_widget.inbox.id }).generate_token }

    it 'refuses a shekel_ key and keeps the contact as it was' do
      patch '/api/v1/widget/contact', params: { website_token: web_widget.website_token, custom_attributes: { shekel_linked: 'true' } },
                                      headers: { 'X-Auth-Token' => token }, as: :json

      expect(response).not_to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'colour' => 'red' })
    end

    it 'still saves other custom attributes' do
      patch '/api/v1/widget/contact', params: { website_token: web_widget.website_token, custom_attributes: { plan: 'pro' } },
                                      headers: { 'X-Auth-Token' => token }, as: :json

      expect(response).to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'colour' => 'red', 'plan' => 'pro' })
    end

    it 'refuses a visitor deleting a shekel_ key' do
      Shekel::TrustedWriter.with { contact.update!(custom_attributes: { 'shekel_linked' => 'true' }) }

      post '/api/v1/widget/contact/destroy_custom_attributes',
           params: { website_token: web_widget.website_token, custom_attributes: ['shekel_linked'] },
           headers: { 'X-Auth-Token' => token }, as: :json

      expect(response).not_to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'shekel_linked' => 'true' })
    end
  end

  describe 'Public API' do
    let(:api_channel) { create(:channel_api, account: account) }
    let(:contact) { create(:contact, account: account, custom_attributes: { 'colour' => 'red' }) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: api_channel.inbox) }

    it 'refuses a shekel_ key on update' do
      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}",
            params: { custom_attributes: { shekel_linked: 'true' } }

      expect(response).not_to have_http_status(:success)
      expect(contact.reload.custom_attributes).to eq({ 'colour' => 'red' })
    end

    it 'refuses a shekel_ key on create' do
      expect do
        post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts", params: { custom_attributes: { shekel_linked: 'true' } }
      end.not_to change(Contact, :count)

      expect(response).not_to have_http_status(:success)
    end
  end
end
