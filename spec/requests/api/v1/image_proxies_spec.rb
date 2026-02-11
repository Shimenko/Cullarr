require "rails_helper"

RSpec.describe "Api::V1::SecurityHeadersAndCsrf", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )

    post "/session", params: {
      session: {
        email: operator.email,
        password: "password123"
      }
    }
  end

  def with_forgery_protection
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  it "returns csrf_invalid for JSON mutating requests without CSRF token" do
    sign_in_operator!

    with_forgery_protection do
      post "/api/v1/security/re-auth", params: { password: "password123" }, as: :json
    end

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("csrf_invalid")
  end

  it "emits a CSP header on authenticated pages" do
    sign_in_operator!

    get "/dashboard"

    expect(response).to have_http_status(:ok)
    csp_header = response.headers["Content-Security-Policy"].to_s
    expect(csp_header).to include("default-src 'self'")
    expect(csp_header).to include("frame-ancestors 'none'")
  end

  it "emits hardened response headers on authenticated pages" do
    sign_in_operator!

    get "/dashboard"

    expect(response.headers["X-Frame-Options"]).to eq(Rails.application.config.action_dispatch.default_headers["X-Frame-Options"])
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    expect(response.headers["Referrer-Policy"]).to eq("strict-origin-when-cross-origin")
  end
end
