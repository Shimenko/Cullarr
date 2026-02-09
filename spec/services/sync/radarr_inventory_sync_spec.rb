require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/ReceiveMessages
RSpec.describe Sync::RadarrInventorySync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual") }

  it "upserts radarr inventory into normalized tables with canonical paths" do
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Sync",
      base_url: "https://radarr.sync.local",
      api_key: "secret",
      verify_ssl: true
    )
    PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::RadarrAdapter)
    allow(Integrations::RadarrAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_movies).and_return(
      [
        {
          radarr_movie_id: 701,
          title: "Example Movie",
          year: 2024,
          tmdb_id: 555_701,
          imdb_id: "tt555701",
          plex_rating_key: "plex-movie-701",
          plex_guid: "plex://movie/701",
          duration_ms: 7_260_000,
          metadata: {}
        }
      ]
    )
    allow(adapter).to receive(:fetch_movie_files).and_return(
      [
        {
          arr_file_id: 8001,
          radarr_movie_id: 701,
          path: "/data/movies/Example Movie (2024)/movie.mkv",
          size_bytes: 3_221_225_472,
          quality: {}
        }
      ]
    )

    result = described_class.new(sync_run:, correlation_id: "corr-radarr").call

    expect(result).to include(integrations: 1, movies_fetched: 1, media_files_fetched: 1, movies_upserted: 1, media_files_upserted: 1)
    movie = Movie.find_by!(integration:, radarr_movie_id: 701)
    media_file = MediaFile.find_by!(integration:, arr_file_id: 8001)
    expect(media_file.attachable).to eq(movie)
    expect(media_file.path_canonical).to eq("/mnt/movies/Example Movie (2024)/movie.mkv")
  end

  it "is idempotent across repeated snapshots by ARR identifiers" do
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Idempotent",
      base_url: "https://radarr.idempotent.local",
      api_key: "secret",
      verify_ssl: true
    )
    PathMapping.create!(integration:, from_prefix: "/data", to_prefix: "/mnt")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::RadarrAdapter)
    allow(Integrations::RadarrAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_movies).and_return(
      [ { radarr_movie_id: 900, title: "First Title", metadata: {} } ],
      [ { radarr_movie_id: 900, title: "Updated Title", metadata: {} } ]
    )
    allow(adapter).to receive(:fetch_movie_files).and_return(
      [ { arr_file_id: 901, radarr_movie_id: 900, path: "/data/movies/one.mkv", size_bytes: 100, quality: {} } ],
      [ { arr_file_id: 901, radarr_movie_id: 900, path: "/data/movies/one.mkv", size_bytes: 200, quality: {} } ]
    )

    described_class.new(sync_run:, correlation_id: "corr-radarr-first").call
    described_class.new(sync_run:, correlation_id: "corr-radarr-second").call

    expect(Movie.where(integration:).count).to eq(1)
    expect(MediaFile.where(integration:).count).to eq(1)
    expect(Movie.find_by!(integration:, radarr_movie_id: 900).title).to eq("Updated Title")
    expect(MediaFile.find_by!(integration:, arr_file_id: 901).size_bytes).to eq(200)
  end

  it "stores canonical paths with separator-safe structure under root mappings" do
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Root Mapping",
      base_url: "https://radarr.root.local",
      api_key: "secret",
      verify_ssl: true
    )
    PathMapping.create!(integration:, from_prefix: "/", to_prefix: "/mnt")

    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::RadarrAdapter)
    allow(Integrations::RadarrAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_movies).and_return(
      [
        {
          radarr_movie_id: 777,
          title: "Root Mapping Movie",
          metadata: {}
        }
      ]
    )
    allow(adapter).to receive(:fetch_movie_files).and_return(
      [
        {
          arr_file_id: 7771,
          radarr_movie_id: 777,
          path: "/movies/Root Mapping Movie/movie.mkv",
          size_bytes: 400,
          quality: {}
        }
      ]
    )

    described_class.new(sync_run:, correlation_id: "corr-radarr-root").call

    media_file = MediaFile.find_by!(integration:, arr_file_id: 7771)
    expect(media_file.path_canonical).to eq("/mnt/movies/Root Mapping Movie/movie.mkv")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/ReceiveMessages
