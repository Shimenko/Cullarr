require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe "Settings", type: :system do
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

  it "persists settings updates from the settings form" do
    sign_in_operator!
    visit "/settings"

    within("form[action='/settings']") do
      fill_in "Sync Interval (minutes)", with: "60"
      click_button "Save Settings"
    end

    expect(page).to have_content("Settings updated.")
    expect(AppSetting.find_by(key: "sync_interval_minutes")&.value_json).to eq(60)
  end

  it "clears managed path roots when textarea is submitted blank" do
    AppSetting.create!(key: "managed_path_roots", value_json: [ "/mnt/media" ])
    sign_in_operator!
    visit "/settings"

    within("form[action='/settings']") do
      fill_in "Managed Path Roots", with: ""
      click_button "Save Settings"
    end

    expect(page).to have_content("Settings updated.")
    expect(AppSetting.find_by(key: "managed_path_roots")&.value_json).to eq([])
  end

  it "creates an integration and runs check from the settings screen" do
    sign_in_operator!
    visit "/settings"

    within("form[action='/security/re_authenticate']") do
      fill_in "Password", with: "password123"
      click_button "Re-authenticate"
    end

    within("form[action='/integrations']") do
      select "sonarr", from: "Kind"
      fill_in "Name", with: "Sonarr Form"
      fill_in "Base URL", with: "https://sonarr.form.local"
      fill_in "API Key", with: "form-secret"
      click_button "Add Integration"
    end

    integration = Integration.find_by!(name: "Sonarr Form")
    checker = instance_double(Integrations::HealthCheck)
    allow(Integrations::HealthCheck).to receive(:new).with(integration).and_return(checker)
    allow(checker).to receive(:call).and_return(
      {
        status: "healthy",
        reported_version: "4.0.5",
        supported_for_delete: true,
        compatibility_mode: "strict_latest"
      }
    )
    integration.update!(status: "healthy", reported_version: "4.0.5")

    click_button "Check"

    expect(page).to have_content("Integration check completed: healthy.")
  end
end
# rubocop:enable RSpec/ExampleLength
