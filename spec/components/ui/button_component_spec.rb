# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ButtonComponent, type: :component do
  it "renders a submit button with variant, size, and icon" do
    fragment = render_inline(
      described_class.new(label: "Sync now", type: :submit, variant: :primary, size: :lg, icon: "loader")
    )

    button = fragment.css("button").first

    expect(button["class"]).to include("ui-button-primary")
    expect(button["class"]).to include("ui-button-lg")
    expect(button["type"]).to eq("submit")
    expect(button.text).to include("Sync now")
    expect(button.css("svg.ui-icon").size).to eq(1)
  end

  it "renders an anchor with disabled semantics when href is provided" do
    fragment = render_inline(described_class.new(label: "Settings", href: "/settings", disabled: true))
    link = fragment.css("a").first

    expect(link["href"]).to eq("/settings")
    expect(link["aria-disabled"]).to eq("true")
    expect(link["tabindex"]).to eq("-1")
  end

  it "raises for unsupported variant" do
    expect { described_class.new(label: "Delete", variant: :invalid) }.to raise_error(
      ArgumentError,
      /invalid variant/
    )
  end
end
