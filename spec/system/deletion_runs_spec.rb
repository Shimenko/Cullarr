require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "DeletionRuns", type: :system do
  before do
    driven_by(:rack_test)
  end

  def sign_in_operator!
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )

    visit "/session/new"
    fill_in "Email", with: operator.email
    fill_in "Password", with: "password123"
    click_button "Sign In"
    operator
  end

  it "shows per-action status details for a deletion run" do
    operator = sign_in_operator!
    integration = Integration.create!(
      kind: "radarr",
      name: "Deletion Runs UI Radarr",
      base_url: "https://deletion-runs.ui.radarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 55_001,
      title: "Deletion Run UI Movie",
      duration_ms: 120_000
    )
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 55_002,
      path: "/media/deletion-run-ui.mkv",
      path_canonical: "/media/deletion-run-ui.mkv",
      size_bytes: 1.gigabyte
    )
    run = DeletionRun.create!(operator: operator, status: "running", scope: "movie")
    DeletionAction.create!(
      deletion_run: run,
      media_file: media_file,
      integration: integration,
      idempotency_key: "deletion-runs-ui:#{media_file.id}",
      status: "running",
      stage_timestamps_json: {}
    )

    visit "/deletion-runs/#{run.id}"

    expect(page).to have_content("Deletion Run ##{run.id}")
    expect(page).to have_content("Status: running")
    expect(page).to have_css("table", text: "running")
    expect(page).to have_link("Back to Runs", href: "/runs")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
