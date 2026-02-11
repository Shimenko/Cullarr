require "rails_helper"

RSpec.describe "Runs", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  def create_completed_sync_run!
    SyncRun.create!(
      status: "success",
      trigger: "manual",
      phase: "complete",
      started_at: 5.minutes.ago,
      finished_at: 1.minute.ago
    )
  end

  it "requires authentication" do
    get "/runs"

    expect(response).to redirect_to("/session/new")
  end

  it "queues a sync run from the html action" do
    sign_in_operator!

    post "/runs/sync-now"

    expect(response).to redirect_to("/runs")
    expect(flash[:notice]).to eq("Sync queued.")
  end

  it "renders runs snapshots without inline progress styles or inline theme style writes" do
    sign_in_operator!
    create_completed_sync_run!

    get "/runs"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ui-progress-track")
    expect(response.body).not_to include("style=\"width:")
    expect(response.body).not_to include("document.documentElement.style.colorScheme")
  end
end
