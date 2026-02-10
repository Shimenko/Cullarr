require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Deletion::CreateDeletionRun, type: :service do
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
      name: "Radarr Create Run",
      base_url: "https://radarr.create-run.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
  end

  let(:operator) { create_operator! }
  let(:env) do
    {
      "CULLARR_DELETE_MODE_ENABLED" => "true",
      "CULLARR_DELETE_MODE_SECRET" => "top-secret"
    }
  end

  def issue_unlock_token!
    Deletion::IssueDeleteModeUnlock.new(
      operator: operator,
      password: "password123",
      correlation_id: "corr-create-run-unlock",
      env: env,
      now: Time.current
    ).call.token
  end

  it "creates queued deletion run and per-media-file actions" do
    integration = create_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 123, title: "Create Run Movie", duration_ms: 100_000)
    first = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4001,
      path: "/media/movies/create-run-a.mkv",
      path_canonical: "/media/movies/create-run-a.mkv",
      size_bytes: 1.gigabyte
    )
    second = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4002,
      path: "/media/movies/create-run-b.mkv",
      path_canonical: "/media/movies/create-run-b.mkv",
      size_bytes: 2.gigabytes
    )

    result = nil
    expect do
      result = described_class.new(
        operator: operator,
        unlock_token: issue_unlock_token!,
        scope: "movie",
        planned_media_file_ids: [ first.id, second.id ],
        plex_user_ids: [],
        action_context: nil,
        correlation_id: "corr-create-run-success",
        env: env
      ).call
    end.to change { AuditEvent.where(event_name: "cullarr.deletion.run_queued").count }.by(1)

    expect(result.success?).to be(true)
    run = result.deletion_run
    expect(run.status).to eq("queued")
    expect(run.deletion_actions.count).to eq(2)
    expect(run.summary_json.fetch("delete_mode_unlock_id")).to be_present
    expect(run.summary_json.fetch("action_context").keys).to contain_exactly(first.id.to_s, second.id.to_s)
    first_context = run.summary_json.fetch("action_context").fetch(first.id.to_s)
    expect(first_context.fetch("unmonitor_target_id")).to eq(movie.radarr_movie_id)
  end

  it "returns validation_failed when media file ids are unknown" do
    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      planned_media_file_ids: [ 999_999 ],
      plex_user_ids: [],
      action_context: nil,
      correlation_id: "corr-create-run-unknown",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("validation_failed")
  end

  it "rejects client-supplied action_context values" do
    integration = create_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 456, title: "Tamper", duration_ms: 100_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4501,
      path: "/media/movies/tamper.mkv",
      path_canonical: "/media/movies/tamper.mkv",
      size_bytes: 1.gigabyte
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      planned_media_file_ids: [ media_file.id ],
      plex_user_ids: [],
      action_context: { media_file.id.to_s => { should_unmonitor: true, unmonitor_target_id: 999_999 } },
      correlation_id: "corr-create-run-action-context-rejected",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("validation_failed")
    expect(result.error_details.fetch(:fields).fetch(:action_context)).to include("is server-derived and cannot be provided")
  end

  it "blocks unsupported integrations at run creation time" do
    integration = create_integration!
    integration.update!(settings_json: integration.settings_json.merge("supported_for_delete" => false))
    movie = Movie.create!(integration: integration, radarr_movie_id: 789, title: "Unsupported", duration_ms: 100_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4601,
      path: "/media/movies/unsupported.mkv",
      path_canonical: "/media/movies/unsupported.mkv",
      size_bytes: 1.gigabyte
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      planned_media_file_ids: [ media_file.id ],
      plex_user_ids: [],
      action_context: nil,
      correlation_id: "corr-create-run-unsupported",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("unsupported_integration_version")
  end

  it "blocks reruns when the same file is already confirmed" do
    integration = create_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 901, title: "Confirmed Once", duration_ms: 100_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4701,
      path: "/media/movies/confirmed-once.mkv",
      path_canonical: "/media/movies/confirmed-once.mkv",
      size_bytes: 1.gigabyte
    )
    prior_run = DeletionRun.create!(
      operator: operator,
      status: "success",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {}
    )
    DeletionAction.create!(
      deletion_run: prior_run,
      media_file: media_file,
      integration: integration,
      idempotency_key: "prior-confirmed:#{media_file.arr_file_id}",
      status: "confirmed"
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      planned_media_file_ids: [ media_file.id ],
      plex_user_ids: [],
      action_context: nil,
      correlation_id: "corr-create-run-confirmed-conflict",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("conflict")
    expect(result.error_message).to include("already confirmed")
  end

  it "blocks reruns when the same file is currently in-flight" do
    integration = create_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 902, title: "Running Once", duration_ms: 100_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4702,
      path: "/media/movies/running-once.mkv",
      path_canonical: "/media/movies/running-once.mkv",
      size_bytes: 1.gigabyte
    )
    prior_run = DeletionRun.create!(
      operator: operator,
      status: "running",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {}
    )
    DeletionAction.create!(
      deletion_run: prior_run,
      media_file: media_file,
      integration: integration,
      idempotency_key: "prior-running:#{media_file.arr_file_id}",
      status: "running"
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      planned_media_file_ids: [ media_file.id ],
      plex_user_ids: [],
      action_context: nil,
      correlation_id: "corr-create-run-running-conflict",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("conflict")
    expect(result.error_message).to include("in progress")
  end

  it "allows reruns when prior actions failed or belong to canceled runs" do
    integration = create_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 903, title: "Retryable", duration_ms: 100_000)
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 4703,
      path: "/media/movies/retryable.mkv",
      path_canonical: "/media/movies/retryable.mkv",
      size_bytes: 1.gigabyte
    )
    failed_run = DeletionRun.create!(
      operator: operator,
      status: "failed",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {}
    )
    canceled_run = DeletionRun.create!(
      operator: operator,
      status: "canceled",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {}
    )
    DeletionAction.create!(
      deletion_run: failed_run,
      media_file: media_file,
      integration: integration,
      idempotency_key: "prior-failed:#{media_file.arr_file_id}",
      status: "failed"
    )
    DeletionAction.create!(
      deletion_run: canceled_run,
      media_file: media_file,
      integration: integration,
      idempotency_key: "prior-canceled:#{media_file.arr_file_id}",
      status: "queued"
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      planned_media_file_ids: [ media_file.id ],
      plex_user_ids: [],
      action_context: nil,
      correlation_id: "corr-create-run-retryable",
      env: env
    ).call

    expect(result.success?).to be(true)
    action = result.deletion_run.deletion_actions.first
    expect(action.idempotency_key).to start_with("run:#{result.deletion_run.id}:integration:#{integration.id}:file:#{media_file.arr_file_id}")
  end

  it "does not escalate tv_show side effects for partial episode selection at create time" do
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Create Run",
      base_url: "https://sonarr.create-run.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
    series = Series.create!(integration: integration, sonarr_series_id: 12_001, title: "Create Scope Show")
    season = Season.create!(series: series, season_number: 1)
    first_episode = Episode.create!(
      integration: integration,
      season: season,
      sonarr_episode_id: 12_101,
      episode_number: 1,
      title: "Episode 1"
    )
    second_episode = Episode.create!(
      integration: integration,
      season: season,
      sonarr_episode_id: 12_102,
      episode_number: 2,
      title: "Episode 2"
    )
    first_file = MediaFile.create!(
      attachable: first_episode,
      integration: integration,
      arr_file_id: 12_201,
      path: "/media/tv/create-scope-show-s01e01.mkv",
      path_canonical: "/media/tv/create-scope-show-s01e01.mkv",
      size_bytes: 1.gigabyte
    )
    MediaFile.create!(
      attachable: second_episode,
      integration: integration,
      arr_file_id: 12_202,
      path: "/media/tv/create-scope-show-s01e02.mkv",
      path_canonical: "/media/tv/create-scope-show-s01e02.mkv",
      size_bytes: 1.gigabyte
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "tv_show",
      planned_media_file_ids: [ first_file.id ],
      plex_user_ids: [],
      action_context: nil,
      correlation_id: "corr-create-run-tv-show-partial",
      env: env
    ).call

    expect(result.success?).to be(true)
    context = result.deletion_run.summary_json.fetch("action_context").fetch(first_file.id.to_s)
    expect(context.fetch("should_unmonitor")).to be(false)
    expect(context.fetch("should_tag")).to be(false)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
