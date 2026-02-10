require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Api::V1::DeletionRuns", type: :request do
  include ActiveJob::TestHelper

  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  def with_delete_mode_env(enabled:, secret:)
    previous_enabled = ENV["CULLARR_DELETE_MODE_ENABLED"]
    previous_secret = ENV["CULLARR_DELETE_MODE_SECRET"]
    ENV["CULLARR_DELETE_MODE_ENABLED"] = enabled
    if secret.nil?
      ENV.delete("CULLARR_DELETE_MODE_SECRET")
    else
      ENV["CULLARR_DELETE_MODE_SECRET"] = secret
    end
    yield
  ensure
    ENV["CULLARR_DELETE_MODE_ENABLED"] = previous_enabled
    ENV["CULLARR_DELETE_MODE_SECRET"] = previous_secret
  end

  def issue_unlock_token!
    post "/api/v1/delete-mode/unlock", params: { password: "password123" }, as: :json
    response.parsed_body.dig("unlock", "token")
  end

  def create_radarr_movie_with_two_versions!
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Delete API",
      base_url: "https://radarr.delete-api.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 1234,
      title: "Versioned Movie",
      duration_ms: 100_000
    )
    first = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 5001,
      path: "/media/movies/versioned-1080p.mkv",
      path_canonical: "/media/movies/versioned-1080p.mkv",
      size_bytes: 2.gigabytes
    )
    second = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 5002,
      path: "/media/movies/versioned-4k.mkv",
      path_canonical: "/media/movies/versioned-4k.mkv",
      size_bytes: 5.gigabytes
    )

    [ movie, first, second ]
  end

  def create_sonarr_show_with_two_episodes!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Delete API",
      base_url: "https://sonarr.delete-api.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
    series = Series.create!(
      integration: integration,
      sonarr_series_id: 8221,
      title: "Request Scope Show"
    )
    season = Season.create!(series: series, season_number: 1)
    first_episode = Episode.create!(
      integration: integration,
      season: season,
      sonarr_episode_id: 8222,
      episode_number: 1,
      title: "Episode 1"
    )
    second_episode = Episode.create!(
      integration: integration,
      season: season,
      sonarr_episode_id: 8223,
      episode_number: 2,
      title: "Episode 2"
    )
    first_file = MediaFile.create!(
      attachable: first_episode,
      integration: integration,
      arr_file_id: 8224,
      path: "/media/tv/request-scope-show-s01e01.mkv",
      path_canonical: "/media/tv/request-scope-show-s01e01.mkv",
      size_bytes: 1.gigabyte
    )
    second_file = MediaFile.create!(
      attachable: second_episode,
      integration: integration,
      arr_file_id: 8225,
      path: "/media/tv/request-scope-show-s01e02.mkv",
      path_canonical: "/media/tv/request-scope-show-s01e02.mkv",
      size_bytes: 1.gigabyte
    )

    [ series, first_file, second_file ]
  end

  describe "POST /api/v1/deletion-runs/plan" do
    it "requires authentication" do
      post "/api/v1/deletion-runs/plan", params: { scope: "movie", selection: { movie_ids: [ 1 ] } }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "returns delete_unlock_required when unlock token is missing" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        movie, = create_radarr_movie_with_two_versions!
        post "/api/v1/deletion-runs/plan",
             params: { scope: "movie", selection: { movie_ids: [ movie.id ] }, version_selection: { "movie:#{movie.id}" => [] } },
             as: :json
      end

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("delete_unlock_required")
    end

    it "returns multi_version_selection_required for implicit all-version deletes" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, = create_radarr_movie_with_two_versions!
        post "/api/v1/deletion-runs/plan",
             params: { unlock_token: token, scope: "movie", selection: { movie_ids: [ movie.id ] }, version_selection: {} },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("multi_version_selection_required")
    end

    it "returns partial-version warning and no parent unmonitor by default" do
      sign_in_operator!
      first = nil

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, = create_radarr_movie_with_two_versions!
        post "/api/v1/deletion-runs/plan",
             params: {
               unlock_token: token,
               scope: "movie",
               selection: { movie_ids: [ movie.id ] },
               version_selection: { "movie:#{movie.id}" => [ first.id ] }
             },
             as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("plan", "warnings")).to include("partial_version_delete_no_parent_unmonitor")
      context = response.parsed_body.dig("plan", "action_context", first.id.to_s)
      expect(context.fetch("should_unmonitor")).to be(false)
    end

    it "returns guardrail blockers and excludes blocked targets from planned ids" do
      sign_in_operator!
      PathExclusion.create!(name: "Never Delete", path_prefix: "/media/excluded")

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, second = create_radarr_movie_with_two_versions!
        first.update!(path_canonical: "/media/excluded/versioned-1080p.mkv", path: "/media/excluded/versioned-1080p.mkv")
        second.update!(path_canonical: "/media/excluded/versioned-4k.mkv", path: "/media/excluded/versioned-4k.mkv")

        post "/api/v1/deletion-runs/plan",
             params: {
               unlock_token: token,
               scope: "movie",
               selection: { movie_ids: [ movie.id ] },
               version_selection: { "movie:#{movie.id}" => [ first.id, second.id ] }
             },
             as: :json
      end

      expect(response).to have_http_status(:ok)
      blockers = response.parsed_body.dig("plan", "blockers")
      expect(blockers.size).to eq(2)
      expect(blockers.first.fetch("error_codes")).to include("guardrail_path_excluded")
      expect(response.parsed_body.dig("plan", "planned_media_file_ids")).to eq([])
    end

    it "returns unsupported_integration_version when planning unsupported integrations" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, second = create_radarr_movie_with_two_versions!
        movie.integration.update!(settings_json: movie.integration.settings_json.merge("supported_for_delete" => false))

        post "/api/v1/deletion-runs/plan",
             params: {
               unlock_token: token,
               scope: "movie",
               selection: { movie_ids: [ movie.id ] },
               version_selection: { "movie:#{movie.id}" => [ first.id, second.id ] }
             },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("unsupported_integration_version")
    end
  end

  describe "POST /api/v1/deletion-runs" do
    it "creates a queued deletion run and enqueues processor job" do
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs

      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, second = create_radarr_movie_with_two_versions!

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "movie",
               planned_media_file_ids: [ first.id, second.id ],
               plex_user_ids: []
             },
             as: :json
      end

      expect(response).to have_http_status(:accepted)
      run_id = response.parsed_body.dig("deletion_run", "id")
      run = DeletionRun.find(run_id)

      expect(run.status).to eq("queued")
      expect(run.deletion_actions.count).to eq(2)
      expect(enqueued_jobs.any? { |job| job[:job] == Deletion::ProcessRunJob }).to be(true)
    ensure
      clear_enqueued_jobs
    end

    it "rejects client-supplied action_context" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, second = create_radarr_movie_with_two_versions!

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "movie",
               planned_media_file_ids: [ first.id, second.id ],
               plex_user_ids: [],
               action_context: {
                 first.id.to_s => {
                   should_unmonitor: true,
                   unmonitor_kind: "movie",
                   unmonitor_target_id: movie.radarr_movie_id
                 }
               }
             },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "action_context")).to include("must not be provided")
    end

    it "returns unsupported_integration_version for unsupported integration targets" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, second = create_radarr_movie_with_two_versions!
        movie.integration.update!(settings_json: movie.integration.settings_json.merge("supported_for_delete" => false))

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "movie",
               planned_media_file_ids: [ first.id, second.id ],
               plex_user_ids: []
             },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("unsupported_integration_version")
    end

    it "returns conflict when the same file is already confirmed in a prior run" do
      operator = sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, = create_radarr_movie_with_two_versions!
        prior_run = DeletionRun.create!(
          operator: operator,
          status: "success",
          scope: "movie",
          selected_plex_user_ids_json: [],
          summary_json: {}
        )
        DeletionAction.create!(
          deletion_run: prior_run,
          media_file: first,
          integration: movie.integration,
          idempotency_key: "prior-confirmed-request:#{first.arr_file_id}",
          status: "confirmed"
        )

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "movie",
               planned_media_file_ids: [ first.id ],
               plex_user_ids: []
             },
             as: :json
      end

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.dig("error", "code")).to eq("conflict")
    end

    it "allows rerun when prior attempts only failed or were canceled" do
      operator = sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, = create_radarr_movie_with_two_versions!
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
          media_file: first,
          integration: movie.integration,
          idempotency_key: "prior-failed-request:#{first.arr_file_id}",
          status: "failed"
        )
        DeletionAction.create!(
          deletion_run: canceled_run,
          media_file: first,
          integration: movie.integration,
          idempotency_key: "prior-canceled-request:#{first.arr_file_id}",
          status: "queued"
        )

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "movie",
               planned_media_file_ids: [ first.id ],
               plex_user_ids: []
             },
             as: :json
      end

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("deletion_run", "status")).to eq("queued")
    end

    it "returns conflict when the same file is in-flight in another active run" do
      operator = sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        movie, first, = create_radarr_movie_with_two_versions!
        active_run = DeletionRun.create!(
          operator: operator,
          status: "running",
          scope: "movie",
          selected_plex_user_ids_json: [],
          summary_json: {}
        )
        DeletionAction.create!(
          deletion_run: active_run,
          media_file: first,
          integration: movie.integration,
          idempotency_key: "prior-running-request:#{first.arr_file_id}",
          status: "running"
        )

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "movie",
               planned_media_file_ids: [ first.id ],
               plex_user_ids: []
             },
             as: :json
      end

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.dig("error", "code")).to eq("conflict")
    end

    it "persists non-escalating context for partial tv_show selections" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        token = issue_unlock_token!
        _series, first_file, = create_sonarr_show_with_two_episodes!

        post "/api/v1/deletion-runs",
             params: {
               unlock_token: token,
               scope: "tv_show",
               planned_media_file_ids: [ first_file.id ],
               plex_user_ids: []
             },
             as: :json
      end

      expect(response).to have_http_status(:accepted)
      run = DeletionRun.find(response.parsed_body.dig("deletion_run", "id"))
      context = run.summary_json.fetch("action_context").fetch(run.deletion_actions.first.media_file_id.to_s)
      expect(context.fetch("should_unmonitor")).to be(false)
      expect(context.fetch("should_tag")).to be(false)
    end
  end

  describe "GET /api/v1/deletion-runs/:id" do
    it "returns stable run/action payload shape" do
      operator = sign_in_operator!
      run = DeletionRun.create!(
        operator: operator,
        status: "running",
        scope: "movie",
        selected_plex_user_ids_json: [],
        summary_json: {}
      )
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Show API",
        base_url: "https://radarr.show-api.local",
        api_key: "secret",
        verify_ssl: true
      )
      movie = Movie.create!(integration: integration, radarr_movie_id: 2233, title: "Show API Movie", duration_ms: 100_000)
      media_file = MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 9011,
        path: "/media/movies/show-api.mkv",
        path_canonical: "/media/movies/show-api.mkv",
        size_bytes: 2.gigabytes
      )
      DeletionAction.create!(
        deletion_run: run,
        media_file: media_file,
        integration: integration,
        idempotency_key: "integration:#{integration.id}:file:#{media_file.arr_file_id}",
        status: "failed",
        error_code: "integration_unreachable",
        error_message: "integration unreachable"
      )

      get "/api/v1/deletion-runs/#{run.id}", as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch("deletion_run")
      expect(payload.fetch("id")).to eq(run.id)
      expect(payload.fetch("summary")).to include("failed" => 1)
      expect(payload.fetch("actions").first).to include(
        "media_file_id" => media_file.id,
        "status" => "failed",
        "error_code" => "integration_unreachable"
      )
    end
  end

  describe "POST /api/v1/deletion-runs/:id/cancel" do
    it "cancels queued runs" do
      operator = sign_in_operator!
      run = DeletionRun.create!(
        operator: operator,
        status: "queued",
        scope: "movie",
        selected_plex_user_ids_json: [],
        summary_json: {}
      )

      post "/api/v1/deletion-runs/#{run.id}/cancel", as: :json

      expect(response).to have_http_status(:ok)
      expect(run.reload.status).to eq("canceled")
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
