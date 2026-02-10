require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Deletion::ProcessRunJob, type: :job do
  it "loads the deletion run and invokes Deletion::ProcessRun" do
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    run = DeletionRun.create!(
      operator: operator,
      status: "queued",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {}
    )
    process_service = instance_double(Deletion::ProcessRun, call: run)
    allow(Deletion::ProcessRun).to receive(:new).with(
      deletion_run: run,
      correlation_id: "corr-process-job"
    ).and_return(process_service)

    described_class.perform_now(run.id, "corr-process-job")

    expect(process_service).to have_received(:call)
  end
end
# rubocop:enable RSpec/ExampleLength
