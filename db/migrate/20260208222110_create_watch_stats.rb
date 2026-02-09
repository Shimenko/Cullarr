class CreateWatchStats < ActiveRecord::Migration[8.0]
  def change
    create_table :watch_stats do |t|
      t.references :plex_user, null: false, foreign_key: true
      t.references :watchable, polymorphic: true, null: false
      t.integer :play_count, null: false, default: 0
      t.datetime :last_watched_at
      t.boolean :watched, null: false, default: false
      t.boolean :in_progress, null: false, default: false
      t.integer :max_view_offset_ms, limit: 8, null: false, default: 0
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :watch_stats, %i[plex_user_id watchable_type watchable_id], unique: true
    add_index :watch_stats, :in_progress
    add_index :watch_stats, :last_watched_at
  end
end
