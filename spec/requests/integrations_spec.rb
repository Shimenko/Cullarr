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
end
# rubocop:enable RSpec/ExampleLength
