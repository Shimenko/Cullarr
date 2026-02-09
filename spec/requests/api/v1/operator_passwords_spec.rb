require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "Api::V1::OperatorPasswords", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
    operator
  end

  it "updates password when current password is valid" do
    operator = sign_in_operator!

    patch "/api/v1/operator_password",
          params: {
            password: {
              current_password: "password123",
              password: "new-password123",
              password_confirmation: "new-password123"
            }
          },
          as: :json

    expect(response).to have_http_status(:ok)
    expect(operator.reload.authenticate("new-password123")).to be_truthy
  end

  it "rejects invalid current password" do
    sign_in_operator!

    patch "/api/v1/operator_password",
          params: {
            password: {
              current_password: "bad-password",
              password: "new-password123",
              password_confirmation: "new-password123"
            }
          },
          as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
  end
end
# rubocop:enable RSpec/ExampleLength
