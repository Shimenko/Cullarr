class AddEpisodePositionLookupIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :episodes, [ :season_id, :episode_number ], name: "index_episodes_on_season_id_and_episode_number"
  end
end
