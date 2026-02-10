require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "runs/_deletion_runs_snapshot.html.erb", type: :view do
  it "uses pre-aggregated summary locals instead of per-run api serialization" do
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    run = DeletionRun.create!(operator: operator, status: "queued", scope: "movie")
    allow(run).to receive(:as_api_json).and_raise("unexpected per-run serialization")

    render partial: "runs/deletion_runs_snapshot", locals: {
      running_deletion_run: run,
      recent_deletion_runs: [ run ],
      deletion_summary_by_run_id: {
        run.id => DeletionRun.default_action_summary.merge(confirmed: 2, failed: 1)
      }
    }

    expect(rendered).to include(">2<")
    expect(rendered).to include(">1<")
  end
end
# rubocop:enable RSpec/ExampleLength
