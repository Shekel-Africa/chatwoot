# Shekel fork: unread counts for an agent narrowed by Shekel::ConversationVisibility.
#
# Upstream's Conversations::UnreadCounts::Counter reads Redis sets keyed by
# inbox, team and label; with one inbox shared by every country those keys
# cannot express "my teams' conversations plus mine" without double counting.
# For a restricted agent the counter calls this instead, which counts the same
# unread conversations (Builder#unread_conversations) from the database after
# the visibility scope. The response shape is the counter's.
class Shekel::UnreadCounts
  # The counts for a restricted agent, or nil to keep upstream's counter.
  def self.for(account:, user:)
    new(account: account, user: user).perform if Shekel::ConversationVisibility.restricted?(user: user, account: account)
  end

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def perform
    # The id keeps DISTINCT from merging conversations that share the other columns.
    rows = visible_unread.pluck(:id, :inbox_id, :team_id, :cached_label_list)
    inboxes = tally(rows.map(&:second))

    {
      all_count: inboxes.values.sum,
      inboxes: inboxes,
      labels: tally(rows.flat_map { |row| label_ids(row.fourth) }),
      teams: tally(rows.filter_map { |row| row.third if own_team_ids.include?(row.third) })
    }
  end

  private

  def visible_unread
    inbox_ids = @user.inboxes.where(account_id: @account.id).select(:id)
    relation = Conversations::UnreadCounts::Builder.new(@account).unread_conversations.where(inbox_id: inbox_ids)
    Shekel::ConversationVisibility.scope(user: @user, account: @account, relation: relation)
  end

  def tally(ids)
    ids.tally.transform_keys(&:to_s)
  end

  def own_team_ids
    @own_team_ids ||= Shekel::ConversationVisibility.team_ids(@user, @account)
  end

  def label_ids(cached_label_list)
    cached_label_list.to_s.split(',').map(&:strip).filter_map { |title| sidebar_labels[title] }
  end

  def sidebar_labels
    @sidebar_labels ||= @account.labels.where(show_on_sidebar: true).pluck(:title, :id).to_h
  end
end
