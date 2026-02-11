require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "Integrations", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )

    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  def reauthenticate!
    post "/security/re_authenticate", params: { password: "password123" }
  end

  describe "POST /integrations/:id/check" do
    it "records health_checked event for healthy status" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "secret",
        verify_ssl: true
      )
      checker = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
      allow(Integrations::HealthCheck).to receive(:new).with(integration).and_return(checker)

      post "/integrations/#{integration.id}/check"

      expect(response).to redirect_to("/settings")
      expect(AuditEvent.order(:created_at).last.event_name).to eq("cullarr.integration.health_checked")
    end

    it "records compatibility_warning event for warning status" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "secret",
        verify_ssl: true
      )
      checker = instance_double(Integrations::HealthCheck, call: { status: "warning" })
      allow(Integrations::HealthCheck).to receive(:new).with(integration).and_return(checker)

      post "/integrations/#{integration.id}/check"

      expect(response).to redirect_to("/settings")
      expect(AuditEvent.order(:created_at).last.event_name).to eq("cullarr.integration.compatibility_warning")
    end

    it "records compatibility_blocked event for unsupported status" do
      sign_in_operator!
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "secret",
        verify_ssl: true
      )
      checker = instance_double(Integrations::HealthCheck, call: { status: "unsupported" })
      allow(Integrations::HealthCheck).to receive(:new).with(integration).and_return(checker)

      post "/integrations/#{integration.id}/check"

      expect(response).to redirect_to("/settings")
      expect(AuditEvent.order(:created_at).last.event_name).to eq("cullarr.integration.compatibility_blocked")
    end
  end

  describe "POST /integrations/:id/reset_history_state" do
    it "clears tautulli history sync state" do
      sign_in_operator!
      reauthenticate!
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Main",
        base_url: "https://tautulli.local",
        api_key: "secret",
        verify_ssl: true,
        settings_json: {
          "history_sync_state" => {
            "watermark_id" => 123,
            "recent_ids" => [ 123 ]
          }
        }
      )

      post "/integrations/#{integration.id}/reset_history_state"

      expect(response).to redirect_to("/settings")
      expect(integration.reload.settings_json).not_to have_key("history_sync_state")
      expect(AuditEvent.order(:created_at).last.payload_json["action"]).to eq("history_state_reset")
    end

    it "rejects reset for non-tautulli integrations" do
      sign_in_operator!
      reauthenticate!
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Main",
        base_url: "https://radarr.local",
        api_key: "secret",
        verify_ssl: true
      )

      post "/integrations/#{integration.id}/reset_history_state"

      expect(response).to redirect_to("/settings")
      expect(flash[:alert]).to include("only available for Tautulli")
    end
  end
end
# rubocop:enable RSpec/ExampleLength
