require "rails_helper"

RSpec.describe "ShellThemes", type: :system do
  before do
    driven_by(:rack_test)
  end

  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  def sign_in!(email: "owner@example.com", password: "password123")
    visit "/session/new"
    fill_in "Email", with: email
    fill_in "Password", with: password
    click_button "Sign In"
  end

  it "applies the default dark theme and keeps shell navigation visible after sign in" do
    create_operator!
    sign_in!

    expect(page).to have_css("body.theme-signal-dark.ui-app")
    expect(page).to have_css("header.ui-topbar")
    expect(page).to have_link("Dashboard")
    expect(page).to have_link("Settings")
    expect(page).to have_link("Runs")
  end

  it "renders tokenized flash styles for notice and alert states" do
    create_operator!
    sign_in!
    click_button "Sign out"

    expect(page).to have_content("Signed out.")
    expect(page).to have_css("div.ui-inline-alert.ui-inline-alert-success", text: "Signed out.")

    fill_in "Email", with: "owner@example.com"
    fill_in "Password", with: "wrong-password"
    click_button "Sign In"

    expect(page).to have_content("Invalid email or password.")
    expect(page).to have_css("div.ui-inline-alert.ui-inline-alert-danger", text: "Invalid email or password.")
  end
end
