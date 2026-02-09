class CreateMovies < ActiveRecord::Migration[8.0]
  def change
    create_table :movies do |t|
      t.references :integration, null: false, foreign_key: true
      t.integer :radarr_movie_id, limit: 8, null: false
      t.string :title, null: false
      t.integer :year
      t.integer :tmdb_id, limit: 8
      t.string :imdb_id
      t.string :plex_rating_key
      t.string :plex_guid
      t.integer :duration_ms, limit: 8
      t.json :metadata_json, null: false, default: {}

      t.timestamps
    end

    add_index :movies, %i[integration_id radarr_movie_id], unique: true
    add_index :movies, %i[title year]
    add_index :movies, :tmdb_id
    add_index :movies, :plex_rating_key
  end
end
