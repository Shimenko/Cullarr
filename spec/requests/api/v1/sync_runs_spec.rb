require "rails_helper"

RSpec.describe "Api::V1::SyncRuns", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  describe "POST /api/v1/sync-runs" do
    it "requires authentication" do
      post "/api/v1/sync-runs", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "queues a new sync run when no run is active" do
      sign_in_operator!

      expect do
        post "/api/v1/sync-runs", params: { trigger: "manual" }, as: :json
      end.to change(SyncRun, :count).by(1)

      expect(response).to have_http_status(:accepted)
      sync_run_payload = response.parsed_body.fetch("sync_run")
      expect(sync_run_payload.fetch("status")).to eq("queued")
      expect(sync_run_payload.fetch("trigger")).to eq("manual")
      expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")
    end

    it "coalesces into queued-next when a run is already running" do
      sign_in_operator!
      running_run = SyncRun.create!(status: "running", trigger: "manual", queued_next: false)

      post "/api/v1/sync-runs", as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.fetch("code")).to eq("sync_queued_next")
      expect(running_run.reload.queued_next).to be(true)
      expect(SyncRun.count).to eq(1)
    end

    it "coalesces manual trigger during a scheduler run with manual lineage" do
      sign_in_operator!
      running_run = SyncRun.create!(status: "running", trigger: "scheduler", queued_next: false)

      post "/api/v1/sync-runs", params: { trigger: "manual" }, as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.fetch("code")).to eq("sync_queued_next")
      expect(queued_next_event_payload_for(running_run.id)).to include("trigger" => "manual")
    end

    it "returns sync_already_running when a queued-next run already exists" do
      sign_in_operator!
      SyncRun.create!(status: "running", trigger: "manual", queued_next: true)

      post "/api/v1/sync-runs", as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.dig("error", "code")).to eq("sync_already_running")
    end

    it "validates trigger values" do
      sign_in_operator!

      post "/api/v1/sync-runs", params: { trigger: "scheduler" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "trigger")).to eq([ "must be manual" ])
    end

    it "returns internal_error envelope for unexpected failures" do
      sign_in_operator!
      trigger_service = instance_double(Sync::TriggerRun)
      allow(Sync::TriggerRun).to receive(:new).and_return(trigger_service)
      allow(trigger_service).to receive(:call).and_raise(StandardError, "boom")

      post "/api/v1/sync-runs", as: :json

      expect(response).to have_http_status(:internal_server_error)
      expect(response.parsed_body.dig("error", "code")).to eq("internal_error")
      expect(response.parsed_body.dig("error", "message")).to include("unexpected error")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
    end
  end

  describe "GET /api/v1/sync-runs" do
    it "returns the recent sync runs for authenticated operators" do
      sign_in_operator!
      older_run = SyncRun.create!(status: "failed", trigger: "manual")
      newer_run = SyncRun.create!(status: "success", trigger: "scheduler")

      get "/api/v1/sync-runs", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("sync_runs", 0, "id")).to eq(newer_run.id)
      expect(response.parsed_body.dig("sync_runs", 1, "id")).to eq(older_run.id)
      expect(response.parsed_body.dig("sync_runs", 0, "progress", "total_phases")).to eq(8)
      expect(response.parsed_body.dig("page", "next_cursor")).to be_nil
    end

    it "returns next_cursor when more records exist than the requested limit" do
      sign_in_operator!
      _first, second, third = create_cursor_pagination_runs!

      get "/api/v1/sync-runs", params: { limit: 2 }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("sync_runs").size).to eq(2)
      expect(response.parsed_body.dig("sync_runs", 0, "id")).to eq(third.id)
      expect(response.parsed_body.dig("sync_runs", 1, "id")).to eq(second.id)
      expect(response.parsed_body.dig("page", "next_cursor")).to eq(second.id)
    end

    it "supports cursor pagination for older runs" do
      sign_in_operator!
      first, second, = create_cursor_pagination_runs!

      get "/api/v1/sync-runs", params: { limit: 2, cursor: second.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("sync_runs").map { |row| row.fetch("id") }).to eq([ first.id ])
      expect(response.parsed_body.dig("page", "next_cursor")).to be_nil
    end

    it "returns continuous cursor pages without duplicate or missing ids" do
      sign_in_operator!
      created_ids = 5.times.map { SyncRun.create!(status: "success", trigger: "manual").id }
      expected_ids = created_ids.sort.reverse

      collected_ids = collect_cursor_page_ids(limit: 2)

      expect(collected_ids).to eq(expected_ids)
      expect(collected_ids.uniq).to eq(expected_ids)
    end

    it "validates cursor format" do
      sign_in_operator!

      get "/api/v1/sync-runs", params: { cursor: "abc" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "cursor")).to eq([ "must be a positive integer" ])
    end
  end

  describe "GET /api/v1/sync-runs/:id" do
    it "returns a sync run record" do
      sign_in_operator!
      sync_run = SyncRun.create!(status: "queued", trigger: "manual")

      get "/api/v1/sync-runs/#{sync_run.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("sync_run", "id")).to eq(sync_run.id)
      expect(response.parsed_body.dig("sync_run", "status")).to eq("queued")
    end

    it "includes additive mapping profile counters in populated mapping phase counts" do
      sign_in_operator!
      sync_run = create_completed_mapping_profile_sync_run!

      get "/api/v1/sync-runs/#{sync_run.id}", as: :json

      mapping_counts = response.parsed_body.dig("sync_run", "phase_counts", "tautulli_library_mapping")
      expect(mapping_counts).to include(
        "profile_bootstrap_integrations" => 1,
        "profile_scheduled_integrations" => 2
      )
    end

    it "returns not_found for missing sync runs" do
      sign_in_operator!

      get "/api/v1/sync-runs/999999", as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_found")
    end
  end

  def create_cursor_pagination_runs!
    [
      SyncRun.create!(status: "failed", trigger: "manual"),
      SyncRun.create!(status: "success", trigger: "scheduler"),
      SyncRun.create!(status: "queued", trigger: "manual")
    ]
  end

  def create_completed_mapping_profile_sync_run!
    SyncRun.create!(
      status: "success",
      trigger: "manual",
      phase_counts_json: {
        "tautulli_library_mapping" => {
          "rows_processed" => 42,
          "profile_bootstrap_integrations" => 1,
          "profile_scheduled_integrations" => 2
        }
      }
    )
  end

  def queued_next_event_payload_for(sync_run_id)
    AuditEvent.where(
      event_name: "cullarr.sync.run_queued_next",
      subject_type: "SyncRun",
      subject_id: sync_run_id
    ).order(occurred_at: :desc, id: :desc).pick(:payload_json)
  end

  def collect_cursor_page_ids(limit:)
    collected_ids = []
    cursor = nil

    loop do
      params = { limit: limit }
      params[:cursor] = cursor if cursor.present?
      get "/api/v1/sync-runs", params:, as: :json
      expect(response).to have_http_status(:ok)

      collected_ids.concat(response.parsed_body.fetch("sync_runs").map { |row| row.fetch("id") })
      cursor = response.parsed_body.dig("page", "next_cursor")
      break if cursor.nil?
    end

    collected_ids
  end
end
