require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "CandidatesDeletionWorkflow", type: :system do
  around do |example|
    previous_enabled = ENV["CULLARR_DELETE_MODE_ENABLED"]
    previous_secret = ENV["CULLARR_DELETE_MODE_SECRET"]
    ENV["CULLARR_DELETE_MODE_ENABLED"] = "true"
    ENV["CULLARR_DELETE_MODE_SECRET"] = "slice-06-secret"
    example.run
  ensure
    ENV["CULLARR_DELETE_MODE_ENABLED"] = previous_enabled
    ENV["CULLARR_DELETE_MODE_SECRET"] = previous_secret
  end

  before do
    driven_by(:selenium, using: :headless_chrome, screen_size: [ 1600, 1400 ])
  rescue StandardError => error
    skip("Selenium driver unavailable: #{error.class} #{error.message}")
  end

  def sign_in_operator!
    visit "/session/new"

    if page.has_button?("Create Operator")
      fill_in "Email", with: "owner@example.com"
      fill_in "Password", with: "password123"
      fill_in "Password confirmation", with: "password123"
      click_button "Create Operator"
    end

    unless page.has_button?("Sign out")
      visit "/session/new"
      fill_in "Email", with: "owner@example.com"
      fill_in "Password", with: "password123"
      click_button "Sign In"
    end

    expect(page).to have_button("Sign out")
  end

  def press_hold_button_for(milliseconds:)
    hold_button = find("[data-candidates-workflow-target='confirmButton']")

    page.execute_script(<<~JS, hold_button.native, milliseconds)
      const element = arguments[0]
      const duration = arguments[1]
      const dispatch = (eventName) => {
        element.dispatchEvent(new MouseEvent(eventName, { bubbles: true, cancelable: true, button: 0 }))
      }

      dispatch("pointerdown")
      dispatch("mousedown")

      if (duration !== null) {
        setTimeout(() => {
          dispatch("pointerup")
          dispatch("mouseup")
        }, duration)
      }
    JS
  end

  it "creates a deletion run from candidates via unlock + plan + hold-to-confirm flow" do
    sign_in_operator!
    integration = Integration.create!(
      kind: "radarr",
      name: "Workflow Radarr",
      base_url: "https://workflow.radarr.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
    user = PlexUser.create!(tautulli_user_id: 6_601, friendly_name: "Workflow User", is_hidden: false)
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 6_602,
      title: "Workflow Movie",
      duration_ms: 100_000
    )
    MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 6_603,
      path: "/media/workflow-movie.mkv",
      path_canonical: "/media/workflow-movie.mkv",
      size_bytes: 2.gigabytes
    )
    WatchStat.create!(plex_user: user, watchable: movie, play_count: 0)

    visit "/candidates"
    expect(page).to have_css("[data-controller='candidates-workflow'][data-workflow-ready='true']", wait: 3)
    page.execute_script(<<~JS, movie.id)
      const movieId = arguments[0]
      const checkbox = document.querySelector(`#candidate_select_movie_${movieId}`)
      checkbox.checked = true
      checkbox.dispatchEvent(new Event("change", { bubbles: true }))
    JS
    page.execute_script("document.querySelector('#delete_mode_password').value = 'password123'")
    page.execute_script("document.querySelector(\"[data-action*='unlockDeleteMode']\").click()")

    expect(page).to have_text("Delete mode unlocked until", wait: 3)

    page.execute_script("document.querySelector(\"[data-action*='reviewPlan']\").click()")
    expect(page).to have_text("Plan ready for 1 target(s).", wait: 3)
    expect(page).to have_css("[data-candidates-workflow-target='planSummary']", visible: true)
    expect(page).to have_css("[data-candidates-workflow-target='planTargetCount']", text: "1")

    press_hold_button_for(milliseconds: 1100)

    expect(page).to have_current_path(%r{/deletion-runs/\d+}, wait: 5)
    expect(page).to have_content("Deletion Run #")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
