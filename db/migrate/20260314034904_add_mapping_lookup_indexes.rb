class AddMappingLookupIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :movies, :imdb_id

    add_index :episodes, :imdb_id
    add_index :episodes, :tmdb_id
    add_index :episodes, :tvdb_id

    add_index :series, :plex_rating_key
    add_index :series, :imdb_id
    add_index :series, :tmdb_id
  end
end
