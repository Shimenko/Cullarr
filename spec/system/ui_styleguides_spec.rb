require "rails_helper"

RSpec.describe "UiStyleguides", type: :system do
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

  it "shows representative component states" do
    sign_in_operator!

    visit "/ui"

    expect(page).to have_content("UI Primitive Styleguide")
    expect(page).to have_css("button.ui-button.ui-button-primary", text: "Primary")
    expect(page).to have_css("span.ui-chip.ui-chip-blocker", text: "In progress")
    expect(page).to have_css("div.ui-inline-alert.ui-inline-alert-danger", text: "Delete blocked")
    expect(page).to have_css("div.ui-progress")
  end
end
