class CreateIntegrations < ActiveRecord::Migration[8.0]
  def change
    create_table :integrations do |t|
      t.string :kind, null: false
      t.string :name, null: false
      t.string :base_url, null: false
      t.text :api_key_ciphertext, null: false
      t.boolean :verify_ssl, null: false, default: true
      t.json :settings_json, null: false, default: {}
      t.string :status, null: false, default: "unknown"
      t.datetime :last_checked_at
      t.text :last_error
      t.string :reported_version

      t.timestamps
    end

    add_index :integrations, :kind
    add_index :integrations, :name, unique: true
  end
end
