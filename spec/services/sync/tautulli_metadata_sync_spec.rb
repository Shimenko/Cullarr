require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Sync::TautulliMetadataSync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual") }

  it "updates watchables that are missing metadata fields" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Metadata Sync",
      base_url: "https://tautulli.metadata.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Metadata Target",
      base_url: "https://radarr.metadata.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: movie_integration,
      radarr_movie_id: 701,
      title: "Example Movie",
      plex_rating_key: "plex-movie-701",
      duration_ms: nil,
      plex_guid: nil
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-movie-701").and_return(
      {
        duration_ms: 7_260_000,
        plex_guid: "plex://movie/701",
        external_ids: {
          imdb_id: "tt555001",
          tmdb_id: 555001
        }
      }
    )

    result = described_class.new(sync_run:, correlation_id: "corr-tautulli-metadata").call

    movie.reload
    expect(result).to include(integrations: 1, metadata_requested: 1, watchables_updated: 1, metadata_skipped: 0)
    expect(movie.duration_ms).to eq(7_260_000)
    expect(movie.plex_guid).to eq("plex://movie/701")
    expect(movie.imdb_id).to eq("tt555001")
    expect(movie.tmdb_id).to eq(555001)
  end
end
# rubocop:enable RSpec/ExampleLength
