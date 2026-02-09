require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe WatchStat, type: :model do
  it "validates uniqueness on plex user and watchable pair" do
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr WatchStat",
      base_url: "https://radarr.watchstat.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(integration: integration, radarr_movie_id: 11, title: "Movie A")
    plex_user = PlexUser.create!(tautulli_user_id: 41, friendly_name: "Alice", is_hidden: false)
    described_class.create!(plex_user: plex_user, watchable: movie)

    duplicate = described_class.new(plex_user: plex_user, watchable: movie)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:watchable_id]).to include("has already been taken")
  end
end
# rubocop:enable RSpec/ExampleLength
