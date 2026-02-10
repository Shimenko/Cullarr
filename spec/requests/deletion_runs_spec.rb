require "rails_helper"

RSpec.describe "DeletionRuns", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  describe "GET /deletion-runs/:id" do
    it "requires authentication" do
      run = DeletionRun.create!(
        operator: Operator.create!(email: "other@example.com", password: "password123", password_confirmation: "password123"),
        status: "queued",
        scope: "movie"
      )

      get "/deletion-runs/#{run.id}"

      expect(response).to redirect_to("/session/new")
    end

    it "renders a deletion run detail view" do
      operator = sign_in_operator!
      run = DeletionRun.create!(operator: operator, status: "queued", scope: "movie")

      get "/deletion-runs/#{run.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Deletion Run ##{run.id}")
      expect(response.body).to include("Scope: movie")
    end
  end
end
