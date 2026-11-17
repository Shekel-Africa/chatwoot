require 'rails_helper'

# Shekel fork: tripwire for upstream rebases. The fork hooks into upstream code
# through prepends, includes, callbacks and small `# Shekel fork:` edits; an
# upstream rename or a lost edit would silently switch a restriction off. Each
# example here names a hook and fails when it no longer reaches the upstream
# method it wraps. When one fails after a rebase, re-apply the hook (grep for
# `Shekel fork:`), do not just update the expectation.
RSpec.describe 'Shekel fork hooks' do # rubocop:disable RSpec/DescribeClass
  # Positional parameters by kind (names may differ, e.g. `_async`), keywords by name.
  def signature(method)
    method.parameters.map { |kind, name| %i[key keyreq].include?(kind) ? [kind, name] : kind }
  end

  # The hook is what the class resolves the method to, and its `super` reaches
  # an upstream method of the same shape.
  def expect_wraps(klass, method_name, hook)
    expect(klass.ancestors.index(hook)).to be < klass.ancestors.index(klass)
    method = klass.instance_method(method_name)
    expect(method.owner).to eq(hook)
    expect(method.super_method).not_to be_nil, "#{klass}##{method_name} has no upstream method left to wrap"
    expect(signature(method.super_method)).to eq(signature(method))
  end

  describe 'prepends' do
    it 'Shekel::ActionCableListenerHooks wraps broadcast, assignee_changed and team_changed' do
      %i[broadcast assignee_changed team_changed].each do |method_name|
        expect_wraps(ActionCableListener, method_name, Shekel::ActionCableListenerHooks)
      end
    end

    it 'Shekel::AuditContext wraps Dispatcher#dispatch' do
      expect_wraps(Dispatcher, :dispatch, Shekel::AuditContext)
    end

    it 'ShekelOidcSignIn wraps the devise_token_auth redirect_callbacks' do
      method = DeviseOverrides::OmniauthCallbacksController.instance_method(:redirect_callbacks)

      expect(method.owner).to eq(ShekelOidcSignIn)
      expect(method.super_method.owner).to eq(DeviseTokenAuth::OmniauthCallbacksController)
      expect(signature(method.super_method)).to eq(signature(method))
    end

    it 'lists every Shekel prepend, so a new one gets a check here' do
      prepended = [ActionCableListener, Dispatcher].flat_map do |klass|
        klass.ancestors.take_while { |ancestor| ancestor != klass }.select { |ancestor| ancestor.name.to_s.start_with?('Shekel') }
      end

      expect(prepended).to contain_exactly(Shekel::ActionCableListenerHooks, Shekel::AuditContext)
    end
  end

  describe 'upstream edits' do
    it 'narrows ActionCableListener events through conversation_members' do
      expect(ActionCableListener.private_method_defined?(:conversation_members)).to be(true)
    end

    it 'keeps Conversations::UnreadCounts::Builder#unread_conversations public for Shekel::UnreadCounts' do
      expect(Conversations::UnreadCounts::Builder.public_method_defined?(:unread_conversations)).to be(true)
    end

    it 'registers Shekel::AuditListener with the async dispatcher' do
      expect(AsyncDispatcher.new.listeners).to include(Shekel::AuditListener.instance)
    end

    it 'refuses personal API tokens in AccessTokenAuthHelper#authenticate_access_token!' do
      file, line = AccessTokenAuthHelper.instance_method(:authenticate_access_token!).source_location
      body = File.readlines(file)[(line - 1)..(line + 12)].join

      expect(body).to include('Shekel::ApiTokens.refused?')
    end
  end

  describe 'controller hooks' do
    def callbacks(controller)
      controller._process_action_callbacks.map(&:filter)
    end

    it 'mounts the password guard on every password surface' do
      expect(callbacks(DeviseOverrides::SessionsController)).to include(:refuse_shekel_password_sign_in)
      expect(callbacks(DeviseOverrides::PasswordsController)).to include(:refuse_shekel_password_management)
      expect(callbacks(DeviseOverrides::RegistrationsController)).to include(:refuse_shekel_password_management)
      expect(callbacks(Api::V1::ProfilesController)).to include(:refuse_shekel_password_change)
      %w[create update destroy].each do |action|
        expect(DeviseOverrides::RegistrationsController.action_methods).to include(action)
      end
    end

    it 'keeps every audited action an action of its controller' do
      audited = {
        Api::V1::Accounts::ConversationsController => %w[show transcript],
        Api::V1::Accounts::Conversations::MessagesController => %w[index],
        Api::V1::Accounts::ContactsController => %w[export],
        Api::V1::Accounts::DataExportsController => %w[create rerun download],
        Api::V1::Accounts::CsatSurveyResponsesController => %w[download],
        Api::V1::Accounts::DataImportsController => Shekel::DataImportAuditHooks::DOWNLOADS,
        Api::V1::Accounts::Shekel::AuditEventsController => %w[index],
        DeviseOverrides::SessionsController => %w[destroy]
      }

      audited.each do |controller, actions|
        expect(controller.action_methods.to_a).to include(*actions), "#{controller} lost an audited action"
      end
      expect(Api::V1::Accounts::ConversationsController).to include(Shekel::ConversationAuditHooks)
      expect(Api::V1::Accounts::ContactsController).to include(Shekel::ContactAuditHooks)
      expect(Api::V1::Accounts::DataImportsController).to include(Shekel::DataImportAuditHooks)
      expect(Api::V1::Accounts::BaseController).to include(ShekelAuditTrail)
    end
  end

  # Every GET route on a single conversation or contact must answer 404 to an
  # agent who cannot see the record, so a new upstream route is covered or noticed.
  describe 'per-record GET routes', type: :request do
    let(:account) { create(:account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:ng_team) { create(:team, account: account, allow_auto_assign: false) }
    let(:ke_team) { create(:team, account: account, allow_auto_assign: false) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:ke_contact) { create(:contact, account: account) }
    let(:ke_conversation) { create(:conversation, account: account, inbox: inbox, team: ke_team, contact: ke_contact) }
    let(:ke_note) { create(:note, account: account, contact: ke_contact, user: create(:user, account: account)) }

    # Routes that need more than the record id. Add a route here only when it
    # genuinely cannot be filled in, and say why.
    let(:skipped) do
      {
        # `new`/`edit` of a note are routed by `resources` but not implemented.
        '/api/v1/accounts/:account_id/contacts/:contact_id/notes/new' => 'notes#new is not an action',
        '/api/v1/accounts/:account_id/contacts/:contact_id/notes/:id/edit' => 'notes#edit is not an action'
      }
    end

    let(:prefixes) do
      {
        %r{\A/api/v1/accounts/:account_id/conversations/:(conversation_id|id)(/|\z)} => :conversation,
        %r{\A/api/v1/accounts/:account_id/contacts/:(contact_id|id)(/|\z)} => :contact
      }
    end

    before do
      allow(Shekel::OidcSettings).to receive(:staff_mode?).and_return(true)
      create(:inbox_member, user: agent, inbox: inbox)
      create(:team_member, team: ng_team, user: agent)
      create(:conversation, account: account, inbox: inbox, team: ng_team) # the agent can see something
    end

    def record_routes
      Rails.application.routes.routes.filter_map do |route|
        next unless route.verb.split('|').include?('GET')

        path = route.path.spec.to_s.delete_suffix('(.:format)')
        kind = prefixes.find { |pattern, _| pattern.match?(path) }&.last
        [path, kind] if kind
      end.uniq
    end

    def fill(path, kind)
      record_id = kind == :conversation ? ke_conversation.display_id : ke_contact.id
      path = path.sub(':account_id', account.id.to_s)
      path = path.sub(/:(conversation_id|contact_id)/, record_id.to_s)
      path = kind == :contact && path.include?('/notes/') ? path.sub(':id', ke_note.id.to_s) : path.sub(':id', record_id.to_s)
      path.include?(':') ? nil : path
    end

    it 'answers 404 for a hidden conversation or contact on every route' do
      routes = record_routes
      expect(routes.map(&:first)).to include('/api/v1/accounts/:account_id/conversations/:id', '/api/v1/accounts/:account_id/contacts/:id')

      unfilled = []
      requested = 0
      routes.each do |template, kind|
        next if skipped.key?(template)

        path = fill(template, kind)
        next unfilled << template if path.nil?

        get path, headers: agent.create_new_auth_token, as: :json
        requested += 1
        expect(response).to have_http_status(:not_found), "GET #{template} answered #{response.status} for a hidden #{kind}"
      end
      expect(requested).to be >= 15 # 17 GET routes at the time of writing
      expect(unfilled).to be_empty, "routes needing more params, add them to `skipped` with a reason: #{unfilled}"
      expect(skipped.keys - routes.map(&:first)).to be_empty, 'a skipped route no longer exists; drop it from the list'
    end
  end
end
