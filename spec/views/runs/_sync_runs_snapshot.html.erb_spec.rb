require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "runs/_sync_runs_snapshot.html.erb", type: :view do
  it "renders active run progress and status badges" do
    running_run = SyncRun.create!(
      status: "running",
      trigger: "manual",
      phase: "tautulli_history",
      queued_next: true,
      started_at: Time.current,
      phase_counts_json: {
        "sonarr_inventory" => { "series_fetched" => 10 }
      }
    )

    render partial: "runs/sync_runs_snapshot", locals: {
      running_sync_run: running_run,
      recent_sync_runs: [ running_run ],
      sync_enabled: true,
      sync_interval_minutes: 30,
      last_successful_sync: nil,
      next_scheduled_sync_at: Time.current
    }

    expect(rendered).to include("Overall run progress")
    expect(rendered).to include("Sync queued next")
    expect(rendered).to include("Tautulli History")
    expect(rendered).to include("Scheduler enabled")
  end
end
# rubocop:enable RSpec/ExampleLength
