# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ChipComponent, type: :component do
  it "renders chip text with semantic kind class" do
    fragment = render_inline(described_class.new(label: "Risk", kind: :risk))
    chip = fragment.css("span.ui-chip").first

    expect(chip["class"]).to include("ui-chip-risk")
    expect(chip.text).to include("Risk")
  end

  it "renders an optional leading icon" do
    fragment = render_inline(described_class.new(label: "Blocked", kind: :blocker, icon: "triangle-alert"))

    expect(fragment.css("svg.ui-icon").size).to eq(1)
  end
end
