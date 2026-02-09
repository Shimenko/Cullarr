require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "Api::V1::KeepMarkers", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  it "creates and deletes a keep marker" do
    sign_in_operator!
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Main",
      base_url: "https://radarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(integration: integration, radarr_movie_id: 42, title: "Example")

    post "/api/v1/keep_markers",
         params: { keep_marker: { keepable_type: "Movie", keepable_id: movie.id, note: "Do not delete" } },
         as: :json

    expect(response).to have_http_status(:created)
    marker_id = response.parsed_body.dig("keep_marker", "id")

    delete "/api/v1/keep_markers/#{marker_id}", as: :json

    expect(response).to have_http_status(:ok)
    expect(KeepMarker.find_by(id: marker_id)).to be_nil
  end

  it "returns validation_failed when keep_marker payload is missing" do
    sign_in_operator!

    post "/api/v1/keep_markers", params: {}, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
    expect(response.parsed_body.dig("error", "details", "fields", "keep_marker")).to eq([ "is required" ])
  end
end
# rubocop:enable RSpec/ExampleLength
