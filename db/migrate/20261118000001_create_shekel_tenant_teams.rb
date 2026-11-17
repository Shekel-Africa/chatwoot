# Shekel fork: maps an authentication-api tenant to the Chatwoot team its staff
# join on sign-in. Team has no attributes column, hence a table of its own.
class CreateShekelTenantTeams < ActiveRecord::Migration[8.0]
  def change
    create_table :shekel_tenant_teams do |t|
      t.bigint :account_id, null: false
      t.string :tenant_id, null: false
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :shekel_tenant_teams, [:account_id, :tenant_id], unique: true
  end
end
