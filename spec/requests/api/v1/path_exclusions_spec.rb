require "rails_helper"

RSpec.describe "Api::V1::PathExclusions", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  it "creates normalized exclusions" do
    sign_in_operator!

    post "/api/v1/path_exclusions",
         params: { path_exclusion: { name: "Kids", path_prefix: "/media//kids/" } },
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("path_exclusion", "path_prefix")).to eq("/media/kids")
  end

  it "deduplicates normalized exclusions" do
    sign_in_operator!
    PathExclusion.create!(name: "Kids", path_prefix: "/media/kids")

    post "/api/v1/path_exclusions",
         params: { path_exclusion: { name: "Kids 2", path_prefix: "/media//kids/" } },
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
  end

  it "returns validation_failed when path_exclusion payload is missing" do
    sign_in_operator!

    post "/api/v1/path_exclusions", params: {}, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
    expect(response.parsed_body.dig("error", "details", "fields", "path_exclusion")).to eq([ "is required" ])
  end
end
