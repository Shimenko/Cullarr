require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "Api::V1::Integrations", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  def reauthenticate!
    post "/api/v1/security/re-auth", params: { password: "password123" }, as: :json
  end

  describe "GET /api/v1/integrations" do
    it "requires authentication" do
      get "/api/v1/integrations", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "returns integration list" do
      sign_in_operator!
      Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "secret",
        verify_ssl: true
      )

      get "/api/v1/integrations", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("integrations").size).to eq(1)
    end
  end

  describe "POST /api/v1/integrations" do
    before { sign_in_operator! }

    it "requires recent re-authentication" do
      post "/api/v1/integrations",
           params: {
             integration: {
               kind: "radarr",
               name: "Radarr 4K",
               base_url: "https://radarr.local",
               api_key: "top-secret",
               verify_ssl: true
             }
           },
           as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
    end

    it "creates integration and never returns cleartext api key" do
      reauthenticate!

      post "/api/v1/integrations",
           params: {
             integration: {
               kind: "radarr",
               name: "Radarr 4K",
               base_url: "https://radarr.local",
               api_key: "top-secret",
               verify_ssl: true,
               settings: {
                 compatibility_mode: "strict_latest",
                 sonarr_fetch_workers: 7,
                 radarr_moviefile_fetch_workers: 6,
                 tautulli_history_page_size: 1200,
                 tautulli_metadata_workers: 9
               }
             }
           },
           as: :json

      expect(response).to have_http_status(:created)
      payload = response.parsed_body.fetch("integration")
      expect(payload.fetch("api_key_present")).to be(true)
      expect(payload).not_to have_key("api_key")
      expect(payload.fetch("tuning")).to include(
        "sonarr_fetch_workers" => 7,
        "sonarr_fetch_workers_resolved" => 7,
        "radarr_moviefile_fetch_workers" => 6,
        "radarr_moviefile_fetch_workers_resolved" => 6,
        "tautulli_history_page_size" => 1200,
        "tautulli_metadata_workers" => 9,
        "tautulli_metadata_workers_resolved" => 9
      )
    end

    it "rejects hosts outside configured integration allow policy" do
      reauthenticate!
      previous_hosts = ENV["CULLARR_ALLOWED_INTEGRATION_HOSTS"]
      ENV["CULLARR_ALLOWED_INTEGRATION_HOSTS"] = "sonarr.local"

      post "/api/v1/integrations",
           params: {
             integration: {
                kind: "radarr",
                name: "Bad Integration",
                base_url: "https://radarr.local",
                api_key: "top-secret",
                verify_ssl: true
              }
            },
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
    ensure
      ENV["CULLARR_ALLOWED_INTEGRATION_HOSTS"] = previous_hosts
    end

    it "returns validation_failed when integration payload is missing" do
      reauthenticate!

      post "/api/v1/integrations", params: {}, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "integration")).to eq([ "is required" ])
    end
  end

  describe "PATCH /api/v1/integrations/:id" do
    before { sign_in_operator! }

    it "requires recent re-authentication" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "initial-key",
        verify_ssl: true
      )

      patch "/api/v1/integrations/#{integration.id}",
            params: {
              integration: {
                name: "Sonarr Main Updated"
              }
            },
            as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
    end

    it "keeps existing encrypted api key when blank api_key is sent" do
      reauthenticate!

      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "initial-key",
        verify_ssl: true
      )
      initial_ciphertext = integration.read_attribute_before_type_cast("api_key_ciphertext")

      patch "/api/v1/integrations/#{integration.id}",
            params: {
              integration: {
                name: "Sonarr Main Updated",
                base_url: "https://sonarr.local",
                api_key: "",
                verify_ssl: true
              }
            },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(integration.reload.read_attribute_before_type_cast("api_key_ciphertext")).to eq(initial_ciphertext)
      expect(integration.name).to eq("Sonarr Main Updated")
    end
  end

  describe "POST /api/v1/integrations/:id/check" do
    before { sign_in_operator! }

    it "maps connectivity failures to integration_unreachable" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "initial-key",
        verify_ssl: true
      )
      checker = instance_double(Integrations::HealthCheck)
      allow(Integrations::HealthCheck).to receive(:new).with(integration).and_return(checker)
      allow(checker).to receive(:call).and_raise(Integrations::ConnectivityError.new("integration unreachable"))

      post "/api/v1/integrations/#{integration.id}/check", as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("error", "code")).to eq("integration_unreachable")
    end

    it "returns updated integration check status" do
      integration = Integration.create!(
        kind: "sonarr",
        name: "Sonarr Main",
        base_url: "https://sonarr.local",
        api_key: "initial-key",
        verify_ssl: true
      )
      checker = instance_double(Integrations::HealthCheck)
      allow(Integrations::HealthCheck).to receive(:new).with(integration).and_return(checker)
      allow(checker).to receive(:call).and_return(
        {
          status: "healthy",
          reported_version: "4.0.5",
          supported_for_delete: true,
          compatibility_mode: "strict_latest"
        }
      )
      integration.update!(status: "healthy", reported_version: "4.0.5")

      post "/api/v1/integrations/#{integration.id}/check", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("integration", "status")).to eq("healthy")
    end
  end

  describe "DELETE /api/v1/integrations/:id" do
    before { sign_in_operator! }

    it "requires recent re-authentication" do
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Main",
        base_url: "https://tautulli.local",
        api_key: "secret",
        verify_ssl: true
      )

      delete "/api/v1/integrations/#{integration.id}", as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
    end

    it "deletes integration after re-authentication" do
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Main",
        base_url: "https://tautulli.local",
        api_key: "secret",
        verify_ssl: true
      )
      reauthenticate!

      delete "/api/v1/integrations/#{integration.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(Integration.find_by(id: integration.id)).to be_nil
    end
  end

  describe "POST /api/v1/integrations/:id/reset_history_state" do
    before { sign_in_operator! }

    it "clears tautulli history and library mapping state after re-authentication" do
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Resettable",
        base_url: "https://tautulli.reset.local",
        api_key: "secret",
        verify_ssl: true,
        settings_json: {
          "history_sync_state" => {
            "watermark_id" => 555,
            "recent_ids" => [ 555, 556 ]
          },
          "library_mapping_state" => {
            "libraries" => {
              "10" => {
                "next_start" => 250
              }
            }
          },
          "library_mapping_bootstrap_completed_at" => "2026-02-14T12:00:00Z"
        }
      )
      reauthenticate!

      post "/api/v1/integrations/#{integration.id}/reset_history_state", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reset"]).to be(true)
      expect(integration.reload.settings_json.keys).not_to include(
        "history_sync_state",
        "library_mapping_state",
        "library_mapping_bootstrap_completed_at"
      )
      expect(response.parsed_body.dig("integration", "tautulli_library_mapping_state", "present")).to be(false)
    end

    it "resets marker-only state when bootstrap marker is the only populated state" do
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
      reauthenticate!

      post "/api/v1/integrations/#{integration.id}/reset_history_state", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reset"]).to be(true)
      expect(integration.reload.settings_json).not_to have_key("library_mapping_bootstrap_completed_at")
    end

    it "returns already_clear when history, mapping state, and marker are all absent" do
      integration = Integration.create!(
        kind: "tautulli",
        name: "Tautulli Already Clear",
        base_url: "https://tautulli.api-already-clear.local",
        api_key: "secret",
        verify_ssl: true,
        settings_json: {}
      )
      prior_settings = integration.settings_json.deep_dup
      reauthenticate!

      post "/api/v1/integrations/#{integration.id}/reset_history_state", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["reset"]).to be(false)
      expect(response.parsed_body["reason"]).to eq("already_clear")
      expect(integration.reload.settings_json).to eq(prior_settings)
    end

    it "returns validation error for non-tautulli integrations" do
      integration = Integration.create!(
        kind: "radarr",
        name: "Radarr Not Resettable",
        base_url: "https://radarr.not-reset.local",
        api_key: "secret",
        verify_ssl: true
      )
      reauthenticate!

      post "/api/v1/integrations/#{integration.id}/reset_history_state", as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "integration")).to include(
        "history state reset is only available for tautulli integrations"
      )
    end
  end
end
# rubocop:enable RSpec/ExampleLength
