require 'rake'
require 'rails_helper'

RSpec.describe 'shekel:configure_agent_bot' do # rubocop:disable RSpec/DescribeClass
  subject(:task) { Rake::Task['shekel:configure_agent_bot'] }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:webhook_url) { 'https://gateway.example.test/chatwoot/webhook?token=url-secret-value' }
  let(:env) do
    { SHEKEL_CHATWOOT_ACCOUNT_ID: account.id.to_s, SHEKEL_SHAILOQ_WEBHOOK_URL: webhook_url, SHEKEL_SHAILOQ_INBOX_ID: inbox.id.to_s }
  end

  before { task.reenable }

  def configure(**overrides)
    with_modified_env(**env, **overrides) { task.invoke }
  end

  it 'creates the Shailoq bot with the webhook url and attaches it to the inbox' do
    expect { configure }.to output(/Attached to inbox #{inbox.id}/).to_stdout

    agent_bot = account.agent_bots.find_by!(name: 'Shailoq')
    expect(agent_bot.outgoing_url).to eq(webhook_url)
    expect(inbox.reload.agent_bot).to eq(agent_bot)
    expect(inbox.agent_bot_inbox).to be_active
  end

  it 'never prints the access token, the webhook secret or the url path and query' do
    expect { configure }.to output(/Settings > Bots.*AgentBot\.find\(\d+\)\.access_token\.token/m).to_stdout

    agent_bot = account.agent_bots.find_by!(name: 'Shailoq')
    printed = capture_stdout_of_rerun
    expect(printed).not_to include(agent_bot.access_token.token)
    expect(printed).not_to include(agent_bot.secret)
    expect(printed).not_to include('url-secret-value')
    expect(printed).not_to include('/chatwoot/webhook')
  end

  it 'is idempotent and keeps the bot, its token and its secret' do
    expect { configure }.to output.to_stdout
    agent_bot = account.agent_bots.find_by!(name: 'Shailoq')
    token = agent_bot.access_token.token
    secret = agent_bot.secret

    task.reenable
    expect { configure }.to output.to_stdout

    expect(account.agent_bots.where(name: 'Shailoq').count).to eq(1)
    expect(AgentBotInbox.where(inbox: inbox).count).to eq(1)
    expect(agent_bot.reload.access_token.token).to eq(token)
    expect(agent_bot.secret).to eq(secret)
  end

  it 'updates the url of the existing bot' do
    expect { configure }.to output.to_stdout
    task.reenable

    expect { configure(SHEKEL_SHAILOQ_WEBHOOK_URL: 'https://gateway.example.test/v2/webhook') }.to output.to_stdout

    expect(account.agent_bots.find_by!(name: 'Shailoq').outgoing_url).to eq('https://gateway.example.test/v2/webhook')
  end

  it 'reactivates an inactive attachment' do
    expect { configure }.to output.to_stdout
    inbox.agent_bot_inbox.inactive!
    task.reenable

    expect { configure }.to output.to_stdout

    expect(inbox.reload.agent_bot_inbox).to be_active
  end

  it 'replaces another bot on the inbox and says so' do
    other_bot = create(:agent_bot, account: account, name: 'Other bot')
    create(:agent_bot_inbox, inbox: inbox, agent_bot: other_bot)

    expect { configure }.to output(/Replaced agent bot Other bot/).to_stdout

    expect(inbox.reload.agent_bot.name).to eq('Shailoq')
  end

  it 'aborts when the webhook url or the inbox id is missing' do
    expect { expect { configure(SHEKEL_SHAILOQ_WEBHOOK_URL: ' ') }.to raise_error(SystemExit) }
      .to output(/Set SHEKEL_SHAILOQ_WEBHOOK_URL and SHEKEL_SHAILOQ_INBOX_ID/).to_stderr
    task.reenable

    expect { expect { configure(SHEKEL_SHAILOQ_INBOX_ID: nil) }.to raise_error(SystemExit) }.to output.to_stderr
    expect(AgentBot.where(name: 'Shailoq')).to be_empty
  end

  it 'aborts on a url that is not http(s)' do
    expect { expect { configure(SHEKEL_SHAILOQ_WEBHOOK_URL: 'gateway.example.test/hook') }.to raise_error(SystemExit) }
      .to output(/must be an http\(s\) URL/).to_stderr
    expect(AgentBot.where(name: 'Shailoq')).to be_empty
  end

  it 'fails for an inbox of another account' do
    other_inbox = create(:inbox)

    expect { configure(SHEKEL_SHAILOQ_INBOX_ID: other_inbox.id.to_s) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(AgentBot.where(name: 'Shailoq')).to be_empty
  end

  def capture_stdout_of_rerun
    task.reenable
    output = StringIO.new
    original = $stdout
    $stdout = output
    configure
    output.string
  ensure
    $stdout = original
  end
end
