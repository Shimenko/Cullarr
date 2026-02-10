require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Deletion::ProcessRun, type: :service do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  def create_integration!
    Integration.create!(
      kind: "radarr",
      name: "Radarr Process Run",
      base_url: "https://radarr.process-run.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
  end

  def create_media_file!(integration:, arr_file_id:)
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 7000 + arr_file_id,
      title: "Process Run Movie #{arr_file_id}",
      duration_ms: 100_000
    )
    MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: arr_file_id,
      path: "/media/movies/process-run-#{arr_file_id}.mkv",
      path_canonical: "/media/movies/process-run-#{arr_file_id}.mkv",
      size_bytes: 1.gigabyte
    )
  end

  def create_run_with_actions!(operator:, integration:, action_count:)
    run = DeletionRun.create!(
      operator: operator,
      status: "queued",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {}
    )
    action_count.times do |index|
      media_file = create_media_file!(integration: integration, arr_file_id: 10_000 + index)
      DeletionAction.create!(
        deletion_run: run,
        media_file: media_file,
        integration: integration,
        idempotency_key: "integration:#{integration.id}:file:#{media_file.arr_file_id}",
        status: "queued",
        stage_timestamps_json: {}
      )
    end
    run
  end

  it "finalizes run as success when all actions confirm" do
    operator = create_operator!
    integration = create_integration!
    run = create_run_with_actions!(operator: operator, integration: integration, action_count: 2)

    allow(Deletion::ProcessAction).to receive(:new) do |deletion_action:, correlation_id:|
      instance_double(
        Deletion::ProcessAction,
        call: deletion_action.update!(status: "confirmed", finished_at: Time.current)
      )
    end

    described_class.new(deletion_run: run, correlation_id: "corr-process-run-success").call

    expect(run.reload.status).to eq("success")
    expect(run.deletion_actions.pluck(:status)).to all(eq("confirmed"))
    expect(AuditEvent.where(event_name: "cullarr.deletion.run_succeeded", subject_id: run.id)).to exist
  end

  it "finalizes run as partial_failure when some actions fail" do
    operator = create_operator!
    integration = create_integration!
    run = create_run_with_actions!(operator: operator, integration: integration, action_count: 2)

    call_index = 0
    allow(Deletion::ProcessAction).to receive(:new) do |deletion_action:, correlation_id:|
      call_index += 1
      status = call_index == 1 ? "confirmed" : "failed"
      instance_double(
        Deletion::ProcessAction,
        call: deletion_action.update!(status: status, finished_at: Time.current)
      )
    end

    described_class.new(deletion_run: run, correlation_id: "corr-process-run-partial").call

    expect(run.reload.status).to eq("partial_failure")
    expect(AuditEvent.where(event_name: "cullarr.deletion.run_partial_failure", subject_id: run.id)).to exist
  end
end
# rubocop:enable RSpec/ExampleLength
