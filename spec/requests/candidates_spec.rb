require "rails_helper"

RSpec.describe "Candidates", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )

    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  describe "GET /candidates" do
    it "requires authentication" do
      get "/candidates"

      expect(response).to redirect_to("/session/new")
    end

    it "renders the unified candidates page for authenticated operators" do
      sign_in_operator!

      get "/candidates"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Candidates")
      expect(response.body).to include("Include blocked candidates")
      expect(response.body).to include("Watched Match")
      expect(response.body).to include("Plex users (leave blank to use all users for watched matching)")
    end
  end
end
