require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "Api::V1::PathMappings", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  it "creates normalized mapping under integration" do
    sign_in_operator!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )

    post "/api/v1/integrations/#{integration.id}/path_mappings",
         params: { path_mapping: { from_prefix: "/data//tv/", to_prefix: "\\mnt\\tv\\" } },
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("path_mapping", "from_prefix")).to eq("/data/tv")
    expect(response.parsed_body.dig("path_mapping", "to_prefix")).to eq("/mnt/tv")
  end

  it "rejects duplicate normalized mapping" do
    sign_in_operator!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    integration.path_mappings.create!(from_prefix: "/data/tv", to_prefix: "/mnt/tv")

    post "/api/v1/integrations/#{integration.id}/path_mappings",
         params: { path_mapping: { from_prefix: "/data//tv/", to_prefix: "/mnt/tv/" } },
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
  end

  it "returns validation_failed when path_mapping payload is missing" do
    sign_in_operator!
    integration = Integration.create!(
      kind: "sonarr",
      name: "Sonarr Main",
      base_url: "https://sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )

    post "/api/v1/integrations/#{integration.id}/path_mappings", params: {}, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
    expect(response.parsed_body.dig("error", "details", "fields", "path_mapping")).to eq([ "is required" ])
  end
end
# rubocop:enable RSpec/ExampleLength
