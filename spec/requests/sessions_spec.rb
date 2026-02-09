require "rails_helper"

RSpec.describe "Sessions", type: :request do
  it "boots the first operator account when no operator exists" do
    expect do
      post "/session", params: {
        operator: {
          email: "owner@example.com",
          password: "password123",
          password_confirmation: "password123"
        }
      }
    end.to change(Operator, :count).by(1)

    expect(response).to redirect_to("/")
  end

  it "authenticates the existing operator" do
    operator = Operator.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123")

    post "/session", params: { session: { email: operator.email, password: "password123" } }
    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Signed in.")
    expect(response.body).to include("ui-inline-alert ui-inline-alert-success")
  end

  it "rejects invalid credentials" do
    operator = Operator.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123")

    post "/session", params: { session: { email: operator.email, password: "wrong-password" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Invalid email or password")
    expect(response.body).to include("ui-inline-alert ui-inline-alert-danger")
  end

  it "renders sign-out flash with auth-page spacing container" do
    operator = Operator.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123")

    post "/session", params: { session: { email: operator.email, password: "password123" } }
    delete "/session"
    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Signed out.")
    expect(response.body).to include("ui-main-flash ui-main-flash-auth")
    expect(response.body).to include("ui-inline-alert ui-inline-alert-success")
  end
end
