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
    it "reports aggregate progress for running runs when only phase completion is known" do
      progress = running_sync_run.progress_snapshot

      expect(progress[:total_phases]).to eq(7)
      expect(progress[:completed_phases]).to eq(2)
      expect(progress[:current_phase]).to eq("tautulli_history")
      expect(progress[:current_phase_label]).to eq("Tautulli History")
      expect(progress[:current_phase_index]).to eq(4)
      expect(progress[:current_phase_percent]).to eq(0.0)
      expect(progress[:percent_complete]).to eq(28.6)
    end

    it "labels each phase with a renderable state" do
      progress = running_sync_run.progress_snapshot

      expect(progress[:percent_complete]).to be > 0
      expect(progress[:phase_states]).to include(
        hash_including(phase: "sonarr_inventory", label: "Sonarr Inventory", state: "complete"),
        hash_including(phase: "radarr_inventory", label: "Radarr Inventory", state: "complete"),
        hash_including(phase: "tautulli_history", label: "Tautulli History", state: "current")
      )
    end

    it "uses data-driven phase totals when progress metadata is present" do
      sync_run = described_class.create!(
        status: "running",
        trigger: "manual",
        phase: "radarr_inventory",
        phase_counts_json: {
          "sonarr_inventory" => { "series_fetched" => 10 },
          Sync::ProgressTracker::PROGRESS_KEY => {
            "version" => 1,
            "phases" => {
              "sonarr_inventory" => { "state" => "complete", "total_units" => 100, "processed_units" => 100 },
              "radarr_inventory" => { "state" => "current", "total_units" => 40, "processed_units" => 10 }
            }
          }
        }
      )

      progress = sync_run.progress_snapshot

      expect(progress[:current_phase_percent]).to eq(25.0)
      expect(progress[:percent_complete]).to eq(17.9)
      expect(progress[:phase_states]).to include(
        {
          phase: "radarr_inventory",
          label: "Radarr Inventory",
          state: "current",
          total_units: 40,
          processed_units: 10,
          percent_complete: 25.0
        }
      )
    end

    it "caps current phase progress below 100 until the phase is complete" do
      sync_run = described_class.create!(
        status: "running",
        trigger: "manual",
        phase: "sonarr_inventory",
        phase_counts_json: {
          Sync::ProgressTracker::PROGRESS_KEY => {
            "version" => 1,
            "phases" => {
              "sonarr_inventory" => { "state" => "current", "total_units" => 10, "processed_units" => 10 }
            }
          }
        }
      )

      progress = sync_run.progress_snapshot

      expect(progress[:current_phase_percent]).to eq(99.9)
      expect(progress[:phase_states]).to include(
        hash_including(
          phase: "sonarr_inventory",
          state: "current",
          percent_complete: 99.9
        )
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
