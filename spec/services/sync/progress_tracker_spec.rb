require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Sync::ProgressTracker, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual", phase: "sonarr_inventory", phase_counts_json: {}) }

  it "tracks per-phase totals and processed units" do
    allow(Sync::RunProgressBroadcaster).to receive(:broadcast)

    tracker = described_class.new(
      sync_run: sync_run,
      correlation_id: "corr-progress-tracker",
      phase_name: "sonarr_inventory",
      broadcast_every: 1
    )

    tracker.start!
    tracker.add_total!(10)
    tracker.advance!(4)

    phase_data = sync_run.reload.progress_snapshot[:phase_states].find { |phase_state| phase_state[:phase] == "sonarr_inventory" }

    expect(phase_data).to include(
      state: "current",
      total_units: 10,
      processed_units: 4,
      percent_complete: 40.0
    )
  end
end
# rubocop:enable RSpec/ExampleLength
