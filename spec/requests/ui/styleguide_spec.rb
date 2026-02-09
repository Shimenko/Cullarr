require "rails_helper"

RSpec.describe "Ui::Styleguide", type: :request do
  def create_operator!
    Operator.create!(email: "owner@example.com", password: "password123", password_confirmation: "password123")
  end

  def sign_in!
    operator = create_operator!
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  it "requires authentication" do
    get "/ui"

    expect(response).to redirect_to("/session/new")
  end

  it "renders for authenticated operators in test" do
    sign_in!

    get "/ui"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("UI Primitive Styleguide")
    expect(response.body).to include("ui-button")
    expect(response.body).to include("ui-progress")
  end

  it "is unavailable when environment is production" do
    sign_in!
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

    get "/ui"

    expect(response).to have_http_status(:not_found)
  end
end
