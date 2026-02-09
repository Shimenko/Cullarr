# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::CheckboxComponent, type: :component do
  def render_repeated_checkboxes
    first_html = render_inline(
      described_class.new(name: "settings[sync_enabled]", label: "Sync enabled")
    ).to_html
    second_html = render_inline(
      described_class.new(name: "settings[sync_enabled]", label: "Sync enabled")
    ).to_html
    fragment = Capybara.string("#{first_html}#{second_html}")
    checkboxes = fragment.all("input[type='checkbox']")
    labels = fragment.all("label.ui-checkbox-label")

    [ fragment, checkboxes, labels ]
  end

  it "renders hidden fallback and checked checkbox" do
    fragment = render_inline(
      described_class.new(name: "settings[sync_enabled]", label: "Sync enabled", checked: true)
    )

    expect(fragment.css("input[type='hidden'][value='0']").size).to eq(1)
    expect(fragment.css("input[type='checkbox'][checked]").size).to eq(1)
  end

  it "can omit hidden input" do
    fragment = render_inline(
      described_class.new(name: "settings[sync_enabled]", label: "Sync enabled", include_hidden: false)
    )

    expect(fragment.css("input[type='hidden']").size).to eq(0)
  end

  it "generates unique ids for repeated controls with the same name" do
    _fragment, checkboxes, labels = render_repeated_checkboxes
    checkbox_ids = checkboxes.map { |element| element["id"] }

    expect(checkbox_ids.uniq.size).to eq(2)
    expect(labels.map { |label| label["for"] }).to match_array(checkbox_ids)
  end

  it "respects explicit ids" do
    fragment = render_inline(
      described_class.new(name: "settings[sync_enabled]", label: "Sync enabled", id: "custom-checkbox-id")
    )
    checkbox = fragment.css("input[type='checkbox']").first
    label = fragment.css("label.ui-checkbox-label").first

    expect(checkbox["id"]).to eq("custom-checkbox-id")
    expect(label["for"]).to eq("custom-checkbox-id")
  end
end
