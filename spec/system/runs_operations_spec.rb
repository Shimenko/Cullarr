require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "RunsOperations", type: :system do
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

  it "shows sync scheduling context and deletion history on runs page" do
    operator = sign_in_operator!
    sync_run = SyncRun.create!(
      status: "running",
      trigger: "manual",
      queued_next: true,
      phase: "tautulli_history",
      started_at: Time.current
    )
    deletion_run = DeletionRun.create!(operator: operator, status: "queued", scope: "movie")

    visit "/runs"

    expect(page).to have_content("Scheduler enabled")
    expect(page).to have_content("Next scheduled sync")
    expect(page).to have_css(".ui-chip.ui-chip-warning", text: "Sync queued next")
    expect(page).to have_content("Deletion Runs")
    expect(page).to have_link("##{deletion_run.id}", href: "/deletion-runs/#{deletion_run.id}")
    expect(page).to have_content("Tautulli History")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
