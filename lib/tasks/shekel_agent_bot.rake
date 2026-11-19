# Shekel fork: create or update the Shailoq agent bot and attach it to its
# WhatsApp inbox, in the account set by SHEKEL_CHATWOOT_ACCOUNT_ID. Safe to run
# on every deploy; prints no secrets.
#
#   SHEKEL_SHAILOQ_WEBHOOK_URL=https://<gateway>/<path> \
#   SHEKEL_SHAILOQ_INBOX_ID=<inbox id> \
#   bundle exec rails shekel:configure_agent_bot
#
# Chatwoot generates the bot's access token and webhook secret on creation and
# keeps them across runs. The task never prints either: it says where to read
# them. Every webhook is signed with the secret (X-Chatwoot-Signature), see
# docs/shekel/OPERATIONS.md.
namespace :shekel do
  desc 'Create or update the Shailoq agent bot and attach it to its inbox (idempotent)'
  task configure_agent_bot: :environment do
    webhook_url = ENV.fetch('SHEKEL_SHAILOQ_WEBHOOK_URL', '').strip
    inbox_id = ENV.fetch('SHEKEL_SHAILOQ_INBOX_ID', '').strip
    abort 'Set SHEKEL_SHAILOQ_WEBHOOK_URL and SHEKEL_SHAILOQ_INBOX_ID' if webhook_url.blank? || inbox_id.blank?

    uri = URI.parse(webhook_url)
    abort 'SHEKEL_SHAILOQ_WEBHOOK_URL must be an http(s) URL with a host' unless uri.is_a?(URI::HTTP) && uri.host.present?

    account = Account.find(Shekel::OidcSettings.account_id)
    inbox = account.inboxes.find(inbox_id)

    agent_bot = account.agent_bots.find_or_initialize_by(name: 'Shailoq')
    agent_bot.update!(outgoing_url: webhook_url)

    agent_bot_inbox = inbox.agent_bot_inbox || AgentBotInbox.new(inbox: inbox)
    replaced_bot = agent_bot_inbox.agent_bot if agent_bot_inbox.agent_bot_id.present? && agent_bot_inbox.agent_bot_id != agent_bot.id
    agent_bot_inbox.update!(agent_bot: agent_bot, status: :active)

    # The URL is not echoed: its query string may carry a secret.
    puts "Agent bot #{agent_bot.name} (id #{agent_bot.id}) posts to #{uri.scheme}://#{uri.host} (path and query not shown)"
    puts "Attached to inbox #{inbox.id} (#{inbox.name}), active"
    puts "Replaced agent bot #{replaced_bot.name} (id #{replaced_bot.id}) on that inbox" if replaced_bot
    puts 'Access token: not printed. Read it in Settings > Bots (administrators), or in a rails console:'
    puts "  AgentBot.find(#{agent_bot.id}).access_token.token"
    puts "Webhook secret: not printed. Read it in Settings > Bots, or AgentBot.find(#{agent_bot.id}).secret (webhooks are signed with it)"
  end
end
