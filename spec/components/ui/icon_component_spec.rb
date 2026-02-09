# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::IconComponent, type: :component do
  it "renders an inline svg icon with expected size attributes" do
    fragment = render_inline(described_class.new(name: "circle-check", size: :sm))
    svg = fragment.css("svg").first

    expect(svg["class"]).to include("ui-icon-sm")
    expect(svg["width"]).to eq("16")
    expect(svg["height"]).to eq("16")
    expect(svg["aria-hidden"]).to eq("true")
  end

  it "supports icon aliases" do
    fragment = render_inline(described_class.new(name: "alert-triangle", size: :md))

    expect(fragment.css("svg.ui-icon-md").size).to eq(1)
  end

  it "requires title for non-decorative icons" do
    expect { described_class.new(name: "info", decorative: false) }.to raise_error(
      ArgumentError,
      /requires title/
    )
  end
end
