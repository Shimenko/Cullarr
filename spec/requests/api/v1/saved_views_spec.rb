require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Api::V1::SavedViews", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  describe "GET /api/v1/saved-views" do
    it "requires authentication" do
      get "/api/v1/saved-views", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthenticated")
    end

    it "returns saved views ordered by name" do
      sign_in_operator!
      SavedView.create!(name: "Z View", scope: "movie", filters_json: {})
      SavedView.create!(name: "A View", scope: "tv_episode", filters_json: {})

      get "/api/v1/saved-views", as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("saved_views").map { |row| row.fetch("name") }).to eq([ "A View", "Z View" ])
    end
  end

  describe "POST /api/v1/saved-views" do
    before { sign_in_operator! }

    it "creates a saved view" do
      post "/api/v1/saved-views", params: {
        saved_view: {
          name: "Watched Movies",
          scope: "movie",
          filters: {
            "plex_user_ids" => [ 1, 2 ],
            "include_blocked" => false
          }
        }
      }, as: :json

      expect(response).to have_http_status(:created)
      expect(response.headers["X-Cullarr-Api-Version"]).to eq("v1")
      expect(response.parsed_body.dig("saved_view", "name")).to eq("Watched Movies")
      expect(response.parsed_body.dig("saved_view", "scope")).to eq("movie")
      expect(response.parsed_body.dig("saved_view", "filters")).to include("plex_user_ids" => [ 1, 2 ])
    end

    it "validates payload fields" do
      post "/api/v1/saved-views", params: {
        saved_view: {
          name: "",
          scope: "bad_scope",
          filters: { "unknown_filter" => true }
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "scope")).to include(
        a_string_including("included in the list")
      )
    end

    it "validates saved view filter value schema" do
      post "/api/v1/saved-views", params: {
        saved_view: {
          name: "Bad Filters",
          scope: "movie",
          filters: {
            "plex_user_ids" => [ 1, "2" ],
            "include_blocked" => "false"
          }
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "filters.plex_user_ids")).to include(
        a_string_including("must be an array of positive integers")
      )
      expect(response.parsed_body.dig("error", "details", "fields", "filters.include_blocked")).to include(
        a_string_including("must be true or false")
      )
    end

    it "rejects non-object filters payloads" do
      post "/api/v1/saved-views", params: {
        saved_view: {
          name: "Bad Filter Type",
          scope: "movie",
          filters: [ 1, 2, 3 ]
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "filters_json")).to include(
        a_string_including("must be an object")
      )
    end

    it "returns validation_failed when saved_view root payload is not an object" do
      post "/api/v1/saved-views", params: { saved_view: "oops" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
      expect(response.parsed_body.dig("error", "details", "fields", "saved_view")).to include(
        a_string_including("must be an object")
      )
    end
  end

  describe "PATCH /api/v1/saved-views/:id" do
    before { sign_in_operator! }

    it "updates a saved view" do
      saved_view = SavedView.create!(name: "My View", scope: "movie", filters_json: { "include_blocked" => false })

      patch "/api/v1/saved-views/#{saved_view.id}", params: {
        saved_view: {
          name: "Updated View",
          scope: "tv_episode",
          filters: { "include_blocked" => true }
        }
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("saved_view", "name")).to eq("Updated View")
      expect(response.parsed_body.dig("saved_view", "scope")).to eq("tv_episode")
      expect(response.parsed_body.dig("saved_view", "filters", "include_blocked")).to be(true)
    end

    it "returns not_found for missing saved views" do
      patch "/api/v1/saved-views/999999", params: {
        saved_view: {
          name: "Missing",
          scope: "movie",
          filters: {}
        }
      }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_found")
    end

    it "returns validation_failed for invalid filter values on update" do
      saved_view = SavedView.create!(name: "Mutable View", scope: "movie", filters_json: {})

      patch "/api/v1/saved-views/#{saved_view.id}", params: {
        saved_view: {
          name: "Mutable View",
          scope: "movie",
          filters: { "include_blocked" => "true" }
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "filters.include_blocked")).to include(
        a_string_including("must be true or false")
      )
    end

    it "rejects non-object filters payloads on update" do
      saved_view = SavedView.create!(name: "Mutable View", scope: "movie", filters_json: {})

      patch "/api/v1/saved-views/#{saved_view.id}", params: {
        saved_view: {
          name: "Mutable View",
          scope: "movie",
          filters: [ 1, 2, 3 ]
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "details", "fields", "filters_json")).to include(
        a_string_including("must be an object")
      )
    end

    it "returns validation_failed when saved_view root payload is not an object on update" do
      saved_view = SavedView.create!(name: "Mutable View", scope: "movie", filters_json: {})

      patch "/api/v1/saved-views/#{saved_view.id}", params: { saved_view: "oops" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
      expect(response.parsed_body.dig("error", "correlation_id")).to be_present
      expect(response.parsed_body.dig("error", "details", "fields", "saved_view")).to include(
        a_string_including("must be an object")
      )
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
