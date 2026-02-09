# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::IconButtonComponent, type: :component do
  it "renders an icon button with aria label" do
    fragment = render_inline(described_class.new(icon: "trash-2", aria_label: "Delete item", variant: :danger))
    button = fragment.css("button").first

    expect(button["aria-label"]).to eq("Delete item")
    expect(button["class"]).to include("ui-icon-button")
    expect(button["class"]).to include("ui-button-danger")
    expect(button.css("svg.ui-icon").size).to eq(1)
  end

  it "raises when aria label is blank" do
    expect { described_class.new(icon: "info", aria_label: "") }.to raise_error(
      ArgumentError,
      /requires aria_label/
    )
  end
end
