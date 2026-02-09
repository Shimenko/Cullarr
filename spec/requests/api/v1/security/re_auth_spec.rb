require "rails_helper"

RSpec.describe "Api::V1::Security::ReAuth", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  it "grants re-auth with valid password" do
    sign_in_operator!
    AppSetting.create!(key: "sensitive_action_reauthentication_window_minutes", value_json: 30)

    post "/api/v1/security/re-auth", params: { password: "password123" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("re_authenticated")).to be(true)
    expires_at = Time.zone.parse(response.parsed_body.fetch("expires_at"))
    expect(expires_at).to be_within(10.seconds).of(30.minutes.from_now)
  end

  it "rejects invalid password" do
    sign_in_operator!

    post "/api/v1/security/re-auth", params: { password: "bad-password" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
  end
end
