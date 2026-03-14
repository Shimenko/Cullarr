require "rails_helper"

RSpec.describe Sync::TautulliLibraryMapping::DiscoveryTraversal, type: :service do
  def build_boundary_telemetry
    discovery_active = false
    row_processor_active_states = []

    telemetry = Object.new
    telemetry.define_singleton_method(:measure_discovery) do |&block|
      raise "nested discovery timing is not allowed in this test" if discovery_active

      discovery_active = true
      block.call
    ensure
      discovery_active = false
    end
    telemetry.define_singleton_method(:record_row_processor_call!) do
      row_processor_active_states << discovery_active
    end
    telemetry.define_singleton_method(:increment_discovery_library_page_calls) do
      nil
    end

    {
      telemetry: telemetry,
      row_processor_active_states: row_processor_active_states
    }
  end

  def build_movie_page
    {
      rows: [
        {
          media_type: "movie",
          title: "Boundary Movie",
          year: 2024,
          plex_rating_key: "plex-boundary-1",
          external_ids: {}
        }
      ],
      raw_rows_count: 1,
      rows_skipped_invalid: 0,
      records_total: 1,
      has_more: false,
      next_start: 1
    }
  end

  def build_adapter
    instance_double(Integrations::TautulliAdapter).tap do |adapter|
      allow(adapter).to receive(:fetch_library_media_page).with(library_id: 10, start: 0, length: 500).and_return(build_movie_page)
    end
  end

  def build_tautulli_integration
    Integration.create!(
      kind: "tautulli",
      name: "Tautulli Discovery Boundary",
      base_url: "https://tautulli.discovery-boundary.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  def build_traversal(telemetry:, row_processor:)
    described_class.new(
      integration: build_tautulli_integration,
      adapter: build_adapter,
      libraries: [ { library_id: 10, title: "Movies", section_type: "movie" } ],
      telemetry: telemetry,
      row_processor: row_processor
    )
  end

  def build_row_processor(telemetry_bundle)
    lambda { |staged_rows|
      telemetry_bundle.fetch(:telemetry).record_row_processor_call!
      raise "expected one staged row" unless staged_rows.size == 1

      {}
    }
  end

  it "does not include row processing inside discovery timing" do
    telemetry_bundle = build_boundary_telemetry
    traversal = build_traversal(
      telemetry: telemetry_bundle.fetch(:telemetry),
      row_processor: build_row_processor(telemetry_bundle)
    )
    result = traversal.call
    expect(result).to include(rows_fetched: 1, rows_invalid: 0, state_updates: 1)
    row_processor_active_states = telemetry_bundle.fetch(:row_processor_active_states)
    expect(row_processor_active_states).to eq([ false ])
  end
end
