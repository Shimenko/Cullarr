require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
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
        file_path: "/mnt/media/movies/Example Movie (2024)/movie.mkv",
        external_ids: {
          imdb_id: "tt555001",
          tmdb_id: 555001
        },
        provenance: {
          endpoint: "get_metadata",
          feed_role: "enrichment_verification",
          source_strength: "strong_enrichment",
          integration_name: tautulli_integration.name,
          integration_kind: tautulli_integration.kind,
          integration_id: tautulli_integration.id,
          signals: {
            file_path: { source: "metadata_media_info_parts_file", raw: "/mnt/media/movies/Example Movie (2024)/movie.mkv", normalized: "/mnt/media/movies/Example Movie (2024)/movie.mkv", value: "/mnt/media/movies/Example Movie (2024)/movie.mkv" },
            imdb_id: { source: "metadata_guids", raw: "imdb://tt555001", normalized: "tt555001", value: "tt555001" },
            tmdb_id: { source: "metadata_guids", raw: "tmdb://555001", normalized: 555001, value: 555001 },
            tvdb_id: { source: "none", raw: nil, normalized: nil, value: nil }
          }
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
    expect(movie.metadata_json).not_to have_key("provenance")
    expect(movie.metadata_json).not_to have_key("file_path")
  end

  it "marks metadata lookup as skipped when adapter raises unexpected errors" do
    tautulli_integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Metadata Error Handling",
      base_url: "https://tautulli.metadata-errors.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "tautulli_metadata_workers" => 1 }
    )
    movie_integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Metadata Error Target",
      base_url: "https://radarr.metadata-errors.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: movie_integration,
      radarr_movie_id: 702,
      title: "Error Movie",
      plex_rating_key: "plex-movie-702",
      duration_ms: nil,
      plex_guid: nil
    )

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration: tautulli_integration).and_return(adapter)
    allow(adapter).to receive(:fetch_metadata).with(rating_key: "plex-movie-702").and_raise(TypeError, "bad nested payload")

    result = described_class.new(sync_run:, correlation_id: "corr-tautulli-metadata-error").call

    movie.reload
    expect(result).to include(integrations: 1, metadata_requested: 1, watchables_updated: 0, metadata_skipped: 1)
    expect(movie.duration_ms).to be_nil
    expect(movie.plex_guid).to be_nil
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
