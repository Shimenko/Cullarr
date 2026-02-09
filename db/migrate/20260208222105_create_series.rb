class CreateSeries < ActiveRecord::Migration[8.0]
  def change
    create_table :series do |t|
      t.references :integration, null: false, foreign_key: true
      t.integer :sonarr_series_id, limit: 8, null: false
      t.string :title, null: false
      t.integer :year
      t.integer :tvdb_id, limit: 8
      t.string :imdb_id
      t.integer :tmdb_id, limit: 8
      t.string :plex_rating_key
      t.string :plex_guid
      t.json :metadata_json, null: false, default: {}

      t.timestamps
    end

    add_index :series, %i[integration_id sonarr_series_id], unique: true
    add_index :series, %i[title year]
    add_index :series, :tvdb_id
  end
end
