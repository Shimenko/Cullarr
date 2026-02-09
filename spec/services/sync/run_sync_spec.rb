require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Sync::RunSync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual", phase_counts_json: {}) }

  it "executes all sync phases and persists phase counts" do
    sonarr_phase = instance_double(Sync::SonarrInventorySync, call: { "fetched" => 1 })
    radarr_phase = instance_double(Sync::RadarrInventorySync, call: { "fetched" => 2 })
    users_phase = instance_double(Sync::TautulliUsersSync, call: { "fetched" => 3 })
    history_phase = instance_double(Sync::TautulliHistorySync, call: { "fetched" => 4 })
    metadata_phase = instance_double(Sync::TautulliMetadataSync, call: { "updated" => 2 })
    mapping_phase = instance_double(Sync::MappingRiskDetectionSync, call: { "ambiguous_path_count" => 0 })
    cleanup_phase = instance_double(Sync::CleanupSync, call: { "stale_running_runs_observed" => 0 })

    allow(Sync::SonarrInventorySync).to receive(:new).and_return(sonarr_phase)
    allow(Sync::RadarrInventorySync).to receive(:new).and_return(radarr_phase)
    allow(Sync::TautulliUsersSync).to receive(:new).and_return(users_phase)
    allow(Sync::TautulliHistorySync).to receive(:new).and_return(history_phase)
    allow(Sync::TautulliMetadataSync).to receive(:new).and_return(metadata_phase)
    allow(Sync::MappingRiskDetectionSync).to receive(:new).and_return(mapping_phase)
    allow(Sync::CleanupSync).to receive(:new).and_return(cleanup_phase)
    allow(Sync::RunProgressBroadcaster).to receive(:broadcast)

    result = described_class.new(sync_run:, correlation_id: "corr-run-sync").call

    expect(result.keys).to eq(
      %w[sonarr_inventory radarr_inventory tautulli_users tautulli_history tautulli_metadata mapping_risk_detection cleanup]
    )
    expect(sync_run.reload.phase_counts_json).to include(
      "tautulli_history" => { "fetched" => 4 },
      "tautulli_metadata" => { "updated" => 2 },
      "mapping_risk_detection" => { "ambiguous_path_count" => 0 }
    )
    expect(
      AuditEvent.where(event_name: "cullarr.sync.phase_started", subject_type: "SyncRun", subject_id: sync_run.id).count
    ).to eq(7)
    expect(
      AuditEvent.where(event_name: "cullarr.sync.phase_completed", subject_type: "SyncRun", subject_id: sync_run.id).count
    ).to eq(7)
  end
end
# rubocop:enable RSpec/ExampleLength
