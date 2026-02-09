require "rails_helper"

RSpec.describe "Settings", type: :request do
  it "requires authentication" do
    get "/settings"

    expect(response).to redirect_to("/session/new")
  end
end
