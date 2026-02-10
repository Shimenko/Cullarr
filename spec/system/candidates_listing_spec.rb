require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "CandidatesListing", type: :system do
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
  end

  def parsed_json_response
    JSON.parse(page.body)
  end

  it "lists movie candidates and honors include_blocked filtering end-to-end" do
    sign_in_operator!

    integration = Integration.create!(
      kind: "radarr",
      name: "System Candidates Radarr",
      base_url: "https://system.candidates.radarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    user = PlexUser.create!(tautulli_user_id: 7101, friendly_name: "System Spec User", is_hidden: false)

    eligible_movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 9101,
      title: "Eligible System Candidate",
      duration_ms: 100_000
    )
    blocked_movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 9102,
      title: "Blocked System Candidate",
      duration_ms: 100_000
    )

    [ eligible_movie, blocked_movie ].each_with_index do |movie, index|
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 11_000 + index,
        path: "/media/system/candidates-#{movie.id}.mkv",
        path_canonical: "/media/system/candidates-#{movie.id}.mkv",
        size_bytes: 1.gigabyte
      )
      WatchStat.create!(plex_user: user, watchable: movie, play_count: 1)
    end

    blocked_watch_stat = WatchStat.find_by!(plex_user: user, watchable: blocked_movie)
    blocked_watch_stat.update!(in_progress: true, max_view_offset_ms: 15_000)

    visit "/api/v1/candidates?scope=movie&plex_user_ids[]=#{user.id}"
    default_payload = parsed_json_response

    expect(default_payload.fetch("scope")).to eq("movie")
    expect(default_payload.dig("filters", "include_blocked")).to be(false)
    expect(default_payload.fetch("items").size).to eq(1)
    expect(default_payload.fetch("items").first.fetch("id")).to eq("movie:#{eligible_movie.id}")

    visit "/api/v1/candidates?scope=movie&include_blocked=true&plex_user_ids[]=#{user.id}"
    with_blocked_payload = parsed_json_response

    expect(with_blocked_payload.dig("filters", "include_blocked")).to be(true)
    ids = with_blocked_payload.fetch("items").map { |row| row.fetch("id") }
    expect(ids).to contain_exactly("movie:#{eligible_movie.id}", "movie:#{blocked_movie.id}")

    blocked_row = with_blocked_payload.fetch("items").find { |row| row.fetch("id") == "movie:#{blocked_movie.id}" }
    expect(blocked_row.fetch("blocker_flags")).to include("in_progress_any")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
