require "rails_helper"

RSpec.describe "UiInteractions", type: :system do
  before do
    driven_by(:selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ])
  rescue StandardError => e
    skip("Selenium driver unavailable: #{e.class} #{e.message}")
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
    hold_button = find("[data-testid='hold-to-confirm-demo']")

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

    hold_button
  end

  it "confirms hold-to-confirm only after sustained input" do
    sign_in_operator!
    visit "/ui"

    press_hold_button_for(milliseconds: nil)

    expect(page).to have_css("[data-testid='hold-to-confirm-demo'][data-hold-to-confirm-state='confirmed']", wait: 1.2)
    expect(page).to have_css("[data-testid='hold-to-confirm-demo'] .ui-button-label", text: "Confirmed")
  end

  it "cancels hold-to-confirm when released before duration" do
    sign_in_operator!
    visit "/ui"

    press_hold_button_for(milliseconds: 120)

    expect(page).to have_css("[data-testid='hold-to-confirm-demo'][data-hold-to-confirm-state='holding']", wait: 0.5)
    expect(page).to have_css("[data-testid='hold-to-confirm-demo'][data-hold-to-confirm-state='idle']", wait: 1.0)
    expect(page).to have_css("[data-testid='hold-to-confirm-demo'] .ui-button-label", text: "Hold to confirm")
  end

  it "shows copy feedback after clipboard action" do
    sign_in_operator!
    visit "/ui"

    page.execute_script("document.execCommand = () => true")
    find("[data-testid='copy-to-clipboard-demo']").click

    expect(page).to have_css("[data-copy-state='success']", text: "Copied to clipboard.")
  end

  it "toggles row expansion state and aria-expanded attributes" do
    sign_in_operator!
    visit "/ui"

    row = find("[data-testid='row-expand-demo']")
    toggle = find("[data-testid='row-expand-toggle']")
    expect(row["data-row-expand-state"]).to eq("collapsed")
    expect(toggle["aria-expanded"]).to eq("false")

    toggle.click

    expect(row["data-row-expand-state"]).to eq("expanded")
    expect(toggle["aria-expanded"]).to eq("true")
  end

  it "reveals row expansion content when toggled" do
    sign_in_operator!
    visit "/ui"

    toggle = find("[data-testid='row-expand-toggle']")
    expect(page).to have_css("#row-expand-content-demo", visible: :hidden)

    toggle.click

    expect(page).to have_css("#row-expand-content-demo", visible: :visible)
  end

  it "supports keyboard row expansion toggling" do
    sign_in_operator!
    visit "/ui"

    toggle = find("[data-testid='row-expand-toggle']")
    toggle.send_keys(:space)

    expect(toggle["aria-expanded"]).to eq("true")
  end
end
