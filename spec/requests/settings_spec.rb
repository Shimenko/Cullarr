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

  it "renders kind-specific tuner groups for integration creation" do
    sign_in_operator!

    get "/settings"

    form = integration_create_form
    expect(form).to be_present
    expect(form.at_css("[data-integration-kind-tuners-target='kindField'] select[name='integration[kind]']")).to be_present
    expect(integration_create_group_fields(form)).to eq(
      "sonarr" => "integration[settings][sonarr_fetch_workers]",
      "radarr" => "integration[settings][radarr_moviefile_fetch_workers]",
      "tautulli" => "integration[settings][tautulli_history_page_size]"
    )
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

  def integration_create_form
    Nokogiri::HTML.parse(response.body).at_css("form[data-controller='integration-kind-tuners']")
  end

  def integration_create_group_fields(form)
    form.css("[data-integration-kind-tuners-target='group'][data-kind]").to_h do |group|
      [ group["data-kind"], group.at_css("input")&.[]("name") ]
    end
  end
end
