require "rails_helper"

RSpec.describe "Settings", type: :request do
  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    post "/session", params: { session: { email: operator.email, password: "password123" } }
  end

  it "requires authentication" do
    get "/settings"

    expect(response).to redirect_to("/session/new")
  end

  it "renders mapping health metrics" do
    sign_in_operator!
    create_metrics_media_file!

    get "/settings"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Mapping Health")
    expect(response.body).to include("Media Files Indexed")
  end

  def create_metrics_media_file!
    integration = Integration.create!(
      kind: "radarr",
      name: "Radarr Metrics",
      base_url: "https://radarr.metrics.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(integration:, radarr_movie_id: 7, title: "Example")
    MediaFile.create!(
      attachable: movie,
      integration:,
      arr_file_id: 9,
      path: "/data/movies/Example.mkv",
      path_canonical: "/mnt/movies/Example.mkv",
      size_bytes: 100
    )
  end
end
