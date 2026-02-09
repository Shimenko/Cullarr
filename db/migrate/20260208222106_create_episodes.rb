class CreateEpisodes < ActiveRecord::Migration[8.0]
  def change
    create_table :episodes do |t|
      t.references :season, null: false, foreign_key: true
      t.references :integration, null: false, foreign_key: true
      t.integer :sonarr_episode_id, limit: 8, null: false
      t.integer :episode_number, null: false
      t.string :title
      t.date :air_date
      t.integer :duration_ms, limit: 8
      t.integer :tvdb_id, limit: 8
      t.string :imdb_id
      t.integer :tmdb_id, limit: 8
      t.string :plex_rating_key
      t.string :plex_guid
      t.json :metadata_json, null: false, default: {}

      t.timestamps
    end

    add_index :episodes, %i[integration_id sonarr_episode_id], unique: true
    add_index :episodes, :duration_ms
    add_index :episodes, :plex_rating_key
  end
end
