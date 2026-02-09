require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  it "redirects unauthenticated requests to sign in" do
    get "/dashboard"

    expect(response).to redirect_to("/session/new")
  end

  it "renders for authenticated operators", :aggregate_failures do
    operator = Operator.create!(email: "operator@example.com", password: "password123", password_confirmation: "password123")

    post "/session", params: { session: { email: operator.email, password: "password123" } }
    get "/dashboard"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("class=\"ui-app\"")
    expect(response.body).to include("prefers-color-scheme: dark")
    expect(response.body).to include("cullarr-theme")
    expect(response.body).to include("Dashboard")
    expect(response.body).to include("Settings")
    expect(response.body).to include("Runs")
  end
end
