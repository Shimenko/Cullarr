require "rails_helper"

RSpec.describe "Runs", type: :request do
  it "requires authentication" do
    get "/runs"

    expect(response).to redirect_to("/session/new")
  end
end
