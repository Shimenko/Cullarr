require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Candidates", type: :system do
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

  it "defaults Plex user filters to all users and can include blocked rows" do
    sign_in_operator!

    integration = Integration.create!(
      kind: "radarr",
      name: "Candidates UI Radarr",
      base_url: "https://candidates.ui.radarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    user_one = PlexUser.create!(tautulli_user_id: 801, friendly_name: "Alice", is_hidden: false)
    user_two = PlexUser.create!(tautulli_user_id: 802, friendly_name: "Bob", is_hidden: false)

    eligible_movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 11_001,
      title: "Eligible Unified Movie",
      duration_ms: 120_000
    )
    blocked_movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 11_002,
      title: "Blocked Unified Movie",
      duration_ms: 120_000
    )

    [ eligible_movie, blocked_movie ].each_with_index do |movie, index|
      MediaFile.create!(
        attachable: movie,
        integration: integration,
        arr_file_id: 20_000 + index,
        path: "/media/candidates/#{movie.id}.mkv",
        path_canonical: "/media/candidates/#{movie.id}.mkv",
        size_bytes: 2.gigabytes
      )

      [ user_one, user_two ].each do |plex_user|
        WatchStat.create!(plex_user: plex_user, watchable: movie, play_count: 1)
      end
    end

    WatchStat.find_by!(plex_user: user_one, watchable: blocked_movie).update!(
      in_progress: true,
      max_view_offset_ms: 15_000
    )

    visit "/candidates"
    expect(page).to have_unchecked_field("candidate_plex_user_#{user_one.id}")
    expect(page).to have_unchecked_field("candidate_plex_user_#{user_two.id}")

    select "All selected users (strict)", from: "Watched Match"
    check "candidate_plex_user_#{user_one.id}"
    check "candidate_plex_user_#{user_two.id}"
    click_button "Apply Filters"

    expect(page).to have_content("Eligible Unified Movie")
    expect(page).to have_css(".ui-chip.ui-chip-instance", text: integration.name)
    expect(page).to have_css(".ui-chip.ui-chip-warning", text: "Unresolved mapping")
    expect(page).to have_text("Recommended action: Check path mappings and external IDs, then rerun sync.")
    expect(page).not_to have_content("Blocked Unified Movie")

    check "Include blocked candidates"
    click_button "Apply Filters"

    expect(page).to have_content("Blocked Unified Movie")
    expect(page).to have_css(".ui-chip.ui-chip-blocker", text: "In Progress")
  end

  it "switches to TV episode scope with the scope selector" do
    sign_in_operator!

    integration = Integration.create!(
      kind: "sonarr",
      name: "Candidates UI Sonarr",
      base_url: "https://candidates.ui.sonarr.local",
      api_key: "secret",
      verify_ssl: true
    )
    plex_user = PlexUser.create!(tautulli_user_id: 803, friendly_name: "Episode User", is_hidden: false)
    series = Series.create!(
      integration: integration,
      sonarr_series_id: 7_101,
      title: "Scoped Series"
    )
    season = Season.create!(series: series, season_number: 1)
    episode = Episode.create!(
      season: season,
      integration: integration,
      sonarr_episode_id: 7_102,
      episode_number: 1,
      title: "Scoped Episode",
      duration_ms: 150_000
    )

    MediaFile.create!(
      attachable: episode,
      integration: integration,
      arr_file_id: 7_103,
      path: "/media/candidates/scoped-episode.mkv",
      path_canonical: "/media/candidates/scoped-episode.mkv",
      size_bytes: 1.5.gigabytes
    )
    WatchStat.create!(plex_user: plex_user, watchable: episode, play_count: 1)

    visit "/candidates"
    select "TV Episode", from: "Scope"
    select "All selected users (strict)", from: "Watched Match"
    check "candidate_plex_user_#{plex_user.id}"
    click_button "Apply Filters"

    expect(page).to have_content("Scoped Episode")
    expect(page).to have_css(".ui-chip.ui-chip-info", text: "TV Episode")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
