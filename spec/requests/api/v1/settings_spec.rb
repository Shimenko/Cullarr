require "rails_helper"

RSpec.describe "Api::V1::Settings", type: :request do
  def parsed_error_code
    response.parsed_body.dig("error", "code")
  end

  def patch_settings(settings:, destructive_confirmations: nil)
    params = { settings: settings }
    params[:destructive_confirmations] = destructive_confirmations if destructive_confirmations
    patch "/api/v1/settings", params: params, as: :json
  end

  def reauthenticate!
    post "/api/v1/security/re-auth", params: { password: "password123" }, as: :json
  end

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

  describe "GET /api/v1/settings" do
    it "requires authentication" do
      get "/api/v1/settings", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to include(
        "error" => include("code" => "unauthenticated")
      )
    end

    it "returns effective settings with source metadata" do
      sign_in_operator!
      AppSetting.create!(key: "sync_interval_minutes", value_json: 45)

      get "/api/v1/settings", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")
      expect(response.parsed_body.fetch("settings")).to include(
        "sync_interval_minutes" => include("value" => 45, "source" => "db"),
        "watched_mode" => include("value" => "play_count", "source" => "default")
      )
    end
  end

  describe "PATCH /api/v1/settings" do
    before { sign_in_operator! }

    it "records an update audit event for valid updates" do
      expect do
        patch_settings(
          settings: {
            sync_enabled: false,
            sync_interval_minutes: 60
          }
        )
      end.to change(AuditEvent, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(AuditEvent.last.event_name).to eq("cullarr.settings.updated")
    end

    it "persists valid settings values" do
      patch_settings(
        settings: {
          sync_enabled: false,
          sync_interval_minutes: 60
        }
      )

      expect(response.parsed_body).to eq("ok" => true)
      expect(AppSetting.find_by(key: "sync_enabled")&.value_json).to be(false)
      expect(AppSetting.find_by(key: "sync_interval_minutes")&.value_json).to eq(60)
    end

    it "persists re-authentication window settings values" do
      patch_settings(
        settings: {
          sensitive_action_reauthentication_window_minutes: 30
        }
      )

      expect(response.parsed_body).to eq("ok" => true)
      expect(AppSetting.find_by(key: "sensitive_action_reauthentication_window_minutes")&.value_json).to eq(30)
    end

    it "rejects immutable settings updates" do
      patch_settings(settings: { delete_mode_enabled: true })

      expect(response).to have_http_status(:unprocessable_content)
      expect(parsed_error_code).to eq("settings_immutable")
    end

    it "rejects invalid values and emits validation_failed" do
      expect do
        patch_settings(settings: { sync_interval_minutes: 0 })
      end.to change(AuditEvent, :count).by(1)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parsed_error_code).to eq("validation_failed")
      expect(AuditEvent.last.event_name).to eq("cullarr.settings.validation_failed")
    end

    it "requires recent re-authentication for retention_audit_events_days set to 0" do
      AppSetting.create!(key: "retention_audit_events_days", value_json: 365)

      patch_settings(settings: { retention_audit_events_days: 0 })

      expect(response).to have_http_status(:forbidden)
      expect(parsed_error_code).to eq("forbidden")
    end

    it "requires explicit confirmation after re-authentication" do
      AppSetting.create!(key: "retention_audit_events_days", value_json: 365)
      reauthenticate!

      patch_settings(settings: { retention_audit_events_days: 0 })

      expect(response).to have_http_status(:unprocessable_content)
      expect(parsed_error_code).to eq("retention_setting_unsafe")
    end

    it "accepts explicit confirmation for retention_audit_events_days set to 0" do
      AppSetting.create!(key: "retention_audit_events_days", value_json: 365)
      reauthenticate!

      expect do
        patch_settings(settings: { retention_audit_events_days: 0 },
                       destructive_confirmations: { retention_audit_events_days_zero: true })
      end.to change(AuditEvent, :count).by(2)

      expect(response).to have_http_status(:ok)
      expect(AuditEvent.order(:created_at).last.event_name).to eq("cullarr.settings.retention_destructive_confirmed")
    end
  end
end
