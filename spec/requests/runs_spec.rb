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
end
