class CreatePlexUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :plex_users do |t|
      t.integer :tautulli_user_id, limit: 8, null: false
      t.string :friendly_name, null: false
      t.boolean :is_hidden, null: false, default: false

      t.timestamps
    end

    add_index :plex_users, :tautulli_user_id, unique: true
  end
end
