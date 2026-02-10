require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Deletion::PlanDeletionRun, type: :service do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  def create_radarr_integration!
    Integration.create!(
      kind: "radarr",
      name: "Radarr Planner",
      base_url: "https://radarr.planner.local",
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
      correlation_id: "corr-plan-issue-unlock",
      env: env,
      now: Time.current
    ).call.token
  end

  it "rejects implicit all-version plans for multi-version movies" do
    integration = create_radarr_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 101, title: "Multi Version", duration_ms: 100_000)
    MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 201,
      path: "/media/movies/multi-a.mkv",
      path_canonical: "/media/movies/multi-a.mkv",
      size_bytes: 1.gigabyte
    )
    MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 202,
      path: "/media/movies/multi-b.mkv",
      path_canonical: "/media/movies/multi-b.mkv",
      size_bytes: 2.gigabytes
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      selection: { movie_ids: [ movie.id ] },
      version_selection: {},
      plex_user_ids: [],
      correlation_id: "corr-plan-multi-required",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("multi_version_selection_required")
  end

  it "builds full-delete context with unmonitor + tag for fully-selected movie versions" do
    integration = create_radarr_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 301, title: "Full Movie", duration_ms: 100_000)
    first = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 401,
      path: "/media/movies/full-a.mkv",
      path_canonical: "/media/movies/full-a.mkv",
      size_bytes: 1.gigabyte
    )
    second = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 402,
      path: "/media/movies/full-b.mkv",
      path_canonical: "/media/movies/full-b.mkv",
      size_bytes: 3.gigabytes
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      selection: { movie_ids: [ movie.id ] },
      version_selection: { "movie:#{movie.id}" => [ first.id, second.id ] },
      plex_user_ids: [],
      correlation_id: "corr-plan-full-movie",
      env: env
    ).call

    expect(result.success?).to be(true)
    plan = result.plan
    expect(plan[:target_count]).to eq(2)
    expect(plan[:total_reclaimable_bytes]).to eq(4.gigabytes)
    expect(plan[:warnings]).to eq([])

    first_context = plan[:action_context][first.id.to_s]
    second_context = plan[:action_context][second.id.to_s]
    expect(first_context[:should_unmonitor]).to be(true)
    expect(first_context[:should_tag]).to be(true)
    expect(second_context[:should_tag]).to be(false)
  end

  it "blocks planning when selected files belong to unsupported integrations" do
    integration = create_radarr_integration!
    integration.update!(settings_json: integration.settings_json.merge("supported_for_delete" => false))
    movie = Movie.create!(integration: integration, radarr_movie_id: 399, title: "Unsupported", duration_ms: 100_000)
    first = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 499,
      path: "/media/movies/unsupported-a.mkv",
      path_canonical: "/media/movies/unsupported-a.mkv",
      size_bytes: 1.gigabyte
    )
    second = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 500,
      path: "/media/movies/unsupported-b.mkv",
      path_canonical: "/media/movies/unsupported-b.mkv",
      size_bytes: 2.gigabytes
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      selection: { movie_ids: [ movie.id ] },
      version_selection: { "movie:#{movie.id}" => [ first.id, second.id ] },
      plex_user_ids: [],
      correlation_id: "corr-plan-unsupported",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("unsupported_integration_version")
  end

  it "adds partial-version warning and disables parent unmonitor for partial movie selection" do
    integration = create_radarr_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 501, title: "Partial Movie", duration_ms: 100_000)
    first = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 601,
      path: "/media/movies/partial-a.mkv",
      path_canonical: "/media/movies/partial-a.mkv",
      size_bytes: 1.gigabyte
    )
    MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 602,
      path: "/media/movies/partial-b.mkv",
      path_canonical: "/media/movies/partial-b.mkv",
      size_bytes: 2.gigabytes
    )

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      selection: { movie_ids: [ movie.id ] },
      version_selection: { "movie:#{movie.id}" => [ first.id ] },
      plex_user_ids: [],
      correlation_id: "corr-plan-partial-movie",
      env: env
    ).call

    expect(result.success?).to be(true)
    expect(result.plan[:warnings]).to include("partial_version_delete_no_parent_unmonitor")
    expect(result.plan[:action_context][first.id.to_s][:should_unmonitor]).to be(false)
  end

  it "returns blockers for excluded paths and omits blocked files from planned targets" do
    integration = create_radarr_integration!
    movie = Movie.create!(integration: integration, radarr_movie_id: 701, title: "Excluded Movie", duration_ms: 100_000)
    first = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 801,
      path: "/media/excluded/blocked-a.mkv",
      path_canonical: "/media/excluded/blocked-a.mkv",
      size_bytes: 1.gigabyte
    )
    second = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 802,
      path: "/media/excluded/blocked-b.mkv",
      path_canonical: "/media/excluded/blocked-b.mkv",
      size_bytes: 2.gigabytes
    )
    PathExclusion.create!(name: "Excluded", path_prefix: "/media/excluded")

    result = described_class.new(
      operator: operator,
      unlock_token: issue_unlock_token!,
      scope: "movie",
      selection: { movie_ids: [ movie.id ] },
      version_selection: { "movie:#{movie.id}" => [ first.id, second.id ] },
      plex_user_ids: [],
      correlation_id: "corr-plan-blocked",
      env: env
    ).call

    expect(result.success?).to be(true)
    expect(result.plan[:planned_media_file_ids]).to eq([])
    expect(result.plan[:blockers].size).to eq(2)
    expect(result.plan[:blockers].first[:error_codes]).to include("guardrail_path_excluded")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
