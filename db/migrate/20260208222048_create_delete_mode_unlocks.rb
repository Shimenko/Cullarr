class CreateDeleteModeUnlocks < ActiveRecord::Migration[8.0]
  def change
    create_table :delete_mode_unlocks do |t|
      t.references :operator, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.timestamps
    end

    add_index :delete_mode_unlocks, :token_digest, unique: true
    add_index :delete_mode_unlocks, :expires_at
  end
end
