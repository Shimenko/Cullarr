require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Api::V1::DeleteMode::Unlocks", type: :request do
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

  describe "POST /api/v1/delete-mode/unlock" do
    it "requires authentication" do
      post "/api/v1/delete-mode/unlock", params: { password: "password123" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "returns delete_mode_disabled when delete mode is disabled" do
      sign_in_operator!

      with_delete_mode_env(enabled: "false", secret: "top-secret") do
        post "/api/v1/delete-mode/unlock", params: { password: "password123" }, as: :json
      end

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("delete_mode_disabled")
    end

    it "returns delete_mode_disabled when delete mode secret is missing" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: nil) do
        post "/api/v1/delete-mode/unlock", params: { password: "password123" }, as: :json
      end

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("delete_mode_disabled")
    end

    it "returns validation_failed when password is missing" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        post "/api/v1/delete-mode/unlock", params: {}, as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "password")).to eq([ "is required" ])
    end

    it "rejects invalid passwords and records denied audit events" do
      sign_in_operator!

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        expect do
          post "/api/v1/delete-mode/unlock", params: { password: "wrong-password" }, as: :json
        end.to change { AuditEvent.where(event_name: "cullarr.security.delete_unlock_denied").count }.by(1)
      end

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
      expect(DeleteModeUnlock.count).to eq(0)
    end

    it "issues an unlock token, persists only digest, and records granted audit events" do
      sign_in_operator!
      AppSetting.create!(key: "sensitive_action_reauthentication_window_minutes", value_json: 30)

      with_delete_mode_env(enabled: "true", secret: "top-secret") do
        expect do
          post "/api/v1/delete-mode/unlock", params: { password: "password123" }, as: :json
        end.to change(DeleteModeUnlock, :count).by(1)
          .and change { AuditEvent.where(event_name: "cullarr.security.delete_unlock_granted").count }.by(1)
      end

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")

      unlock_payload = response.parsed_body.fetch("unlock")
      token = unlock_payload.fetch("token")
      expires_at = Time.zone.parse(unlock_payload.fetch("expires_at"))
      unlock_record = DeleteModeUnlock.last

      expect(token).to be_present
      expect(unlock_record.token_digest).to eq(DeleteModeUnlock.digest_for(token: token, secret: "top-secret"))
      expect(unlock_record.token_digest).not_to eq(token)
      expect(expires_at).to be_within(10.seconds).of(30.minutes.from_now)
      expect(unlock_record.expires_at).to be_within(10.seconds).of(30.minutes.from_now)
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
