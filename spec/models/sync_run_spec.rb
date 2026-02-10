require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe SyncRun, type: :model do
  let(:running_sync_run) do
    described_class.create!(
      status: "running",
      trigger: "manual",
      phase: "tautulli_history",
      phase_counts_json: {
        "sonarr_inventory" => { "series_fetched" => 10 },
        "radarr_inventory" => { "movies_fetched" => 5 }
      }
    )
  end

  describe "#progress_snapshot" do
    it "reports aggregate progress for running runs" do
      progress = running_sync_run.progress_snapshot

      expect(progress[:total_phases]).to eq(7)
      expect(progress[:completed_phases]).to eq(2)
      expect(progress[:current_phase]).to eq("tautulli_history")
      expect(progress[:current_phase_label]).to eq("Tautulli History")
      expect(progress[:current_phase_index]).to eq(4)
      expect(progress[:percent_complete]).to eq(35.7)
    end

    it "labels each phase with a renderable state" do
      progress = running_sync_run.progress_snapshot

      expect(progress[:percent_complete]).to be > 0
      expect(progress[:phase_states]).to include(
        { phase: "sonarr_inventory", label: "Sonarr Inventory", state: "complete" },
        { phase: "radarr_inventory", label: "Radarr Inventory", state: "complete" },
        { phase: "tautulli_history", label: "Tautulli History", state: "current" }
      )
    end

    it "reports 100 percent for successful runs" do
      sync_run = described_class.create!(
        status: "success",
        trigger: "manual",
        phase: "complete",
        phase_counts_json: Sync::RunSync.phase_order.index_with { {} },
        started_at: 5.minutes.ago,
        finished_at: Time.current
      )

      progress = sync_run.progress_snapshot

      expect(progress[:percent_complete]).to eq(100.0)
      expect(progress[:completed_phases]).to eq(progress[:total_phases])
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
