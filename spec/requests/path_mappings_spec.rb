require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "PathMappings", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )

    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  it "records audit event for create" do
    operator = sign_in_operator!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )

    expect do
      post "/integrations/#{integration.id}/path_mappings",
           params: { path_mapping: { from_prefix: "/data/tv", to_prefix: "/mnt/tv", enabled: true } }
    end.to change(AuditEvent, :count).by(1)

    mapping = integration.path_mappings.order(:created_at).last
    event = AuditEvent.order(:created_at).last

    expect(response).to redirect_to("/settings")
    expect(event.event_name).to eq("cullarr.integration.updated")
    expect(event.correlation_id).to be_present
    expect(event.operator_id).to eq(operator.id)
    expect(event.subject_type).to eq("PathMapping")
    expect(event.subject_id).to eq(mapping.id)
    expect(event.payload_json.fetch("action")).to eq("path_mapping_created")
  end

  it "records audit event for update" do
    operator = sign_in_operator!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    mapping = integration.path_mappings.create!(from_prefix: "/data/tv", to_prefix: "/mnt/tv", enabled: true)

    expect do
      patch "/integrations/#{integration.id}/path_mappings/#{mapping.id}",
            params: { path_mapping: { to_prefix: "/srv/tv" } }
    end.to change(AuditEvent, :count).by(1)

    event = AuditEvent.order(:created_at).last

    expect(response).to redirect_to("/settings")
    expect(event.event_name).to eq("cullarr.integration.updated")
    expect(event.correlation_id).to be_present
    expect(event.operator_id).to eq(operator.id)
    expect(event.subject_type).to eq("PathMapping")
    expect(event.subject_id).to eq(mapping.id)
    expect(event.payload_json.fetch("action")).to eq("path_mapping_updated")
  end

  it "records audit event for destroy" do
    operator = sign_in_operator!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    mapping = integration.path_mappings.create!(from_prefix: "/data/tv", to_prefix: "/mnt/tv", enabled: true)

    expect do
      delete "/integrations/#{integration.id}/path_mappings/#{mapping.id}"
    end.to change(AuditEvent, :count).by(1)

    event = AuditEvent.order(:created_at).last

    expect(response).to redirect_to("/settings")
    expect(event.event_name).to eq("cullarr.integration.updated")
    expect(event.correlation_id).to be_present
    expect(event.operator_id).to eq(operator.id)
    expect(event.subject_type).to eq("PathMapping")
    expect(event.subject_id).to eq(mapping.id)
    expect(event.payload_json.fetch("action")).to eq("path_mapping_deleted")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
