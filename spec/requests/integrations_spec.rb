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
    it "clears tautulli history and library mapping sync state" do
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
          },
          "library_mapping_state" => {
            "libraries" => {
              "1" => {
                "next_start" => 100
              }
            }
          },
          "library_mapping_bootstrap_completed_at" => "2026-02-14T12:00:00Z"
        }
      )

      post "/integrations/#{integration.id}/reset_history_state"

      expect(response).to redirect_to("/settings")
      expect(integration.reload.settings_json.keys).not_to include(
        "history_sync_state",
        "library_mapping_state",
        "library_mapping_bootstrap_completed_at"
      )
      payload = AuditEvent.order(:created_at).last.payload_json
      expect(payload["action"]).to eq("history_state_reset")
      expect(payload["prior_library_mapping_bootstrap_completed_at"]).to eq("2026-02-14T12:00:00Z")
    end

    it "resets marker-only state for tautulli integrations" do
      sign_in_operator!
      reauthenticate!
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Marker Only",
        base_url: "https://tautulli.marker-only.local",
        api_key: "secret",
        verify_ssl: true,
        settings_json: {
          "library_mapping_bootstrap_completed_at" => "2026-02-14T13:00:00Z"
        }
      )

      post "/integrations/#{integration.id}/reset_history_state"

      expect(response).to redirect_to("/settings")
      expect(integration.reload.settings_json).not_to have_key("library_mapping_bootstrap_completed_at")
    end

    it "returns already-clear notice when history, mapping state, and marker are all absent" do
      sign_in_operator!
      reauthenticate!
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Already Clear",
        base_url: "https://tautulli.already-clear.local",
        api_key: "secret",
        verify_ssl: true,
        settings_json: {}
      )
      prior_settings = integration.settings_json.deep_dup

      post "/integrations/#{integration.id}/reset_history_state"

      expect(response).to redirect_to("/settings")
      expect(flash[:notice]).to eq("History sync state is already clear.")
      expect(integration.reload.settings_json).to eq(prior_settings)
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
