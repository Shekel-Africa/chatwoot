require 'rails_helper'

# Shekel fork: deny by default. See Shekel::LockedContactAttributes.
RSpec.describe Shekel::LockedContactAttributes do
  let(:account) { create(:account) }
  let(:service_user) { create(:user, account: account, role: :agent) }
  let(:contact) { Shekel::TrustedWriter.with { create(:contact, account: account, custom_attributes: { 'shekel_dealer_id' => 'd-1' }) } }

  around do |example|
    with_modified_env(SHEKEL_API_USER_IDS: service_user.id.to_s) { example.run }
  end

  after { Current.reset }

  it 'refuses a save with no signed-in actor, as in a background job or the console' do
    Current.reset

    expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-2' })).to be(false)
    expect(contact.errors[:custom_attributes]).to be_present
    expect(contact.reload.custom_attributes).to eq({ 'shekel_dealer_id' => 'd-1' })
  end

  it 'refuses a new contact with a shekel_ key and no actor' do
    new_contact = build(:contact, account: account, custom_attributes: { 'shekel_linked' => 'true' })

    expect(new_contact).not_to be_valid
  end

  it 'refuses an agent bot as the actor' do
    Current.user = create(:agent_bot, account: account)

    expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-2' })).to be(false)
  end

  it 'refuses a user who is not the service user' do
    Current.user = create(:user, account: account, role: :administrator)

    expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-2' })).to be(false)
  end

  it 'allows the service user' do
    Current.user = service_user

    expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-2', 'shekel_tenant_id' => 't-1' })).to be(true)
  end

  it 'allows a block marked with Shekel::TrustedWriter and refuses again after it, even after an error' do
    Shekel::TrustedWriter.with do
      expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-2' })).to be(true)
    end
    expect { Shekel::TrustedWriter.with { raise 'boom' } }.to raise_error('boom')

    expect(Shekel::TrustedWriter).not_to be_active
    expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-3' })).to be(false)
  end

  it 'accepts other attributes and unchanged shekel_ values from anyone' do
    expect(contact.update(custom_attributes: { 'shekel_dealer_id' => 'd-1', 'colour' => 'red' })).to be(true)
  end
end
