require "rails_helper"

RSpec.describe "API v1 health", type: :request do
  it "returns unauthenticated envelope when not signed in" do
    get "/api/v1/health", headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    expect(response.headers["X-Correlation-Id"]).to be_present
    expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")
  end

  it "returns ok payload for authenticated operator" do
    operator = Operator.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123")
    post "/session", params: { session: { email: operator.email, password: "password123" } }

    get "/api/v1/health", headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok")
    expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")
  end
end
