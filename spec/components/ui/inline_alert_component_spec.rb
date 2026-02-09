# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::InlineAlertComponent, type: :component do
  it "maps flash keys and renders matching style" do
    kind = described_class.kind_for_flash_key(:alert)
    fragment = render_inline(described_class.new(message: "Invalid token", kind:))

    expect(fragment.css("div.ui-inline-alert-danger").size).to eq(1)
    expect(fragment.css("svg.ui-icon").size).to eq(1)
    expect(fragment.text).to include("Invalid token")
  end

  it "rejects invalid kinds" do
    expect { described_class.new(message: "x", kind: :critical) }.to raise_error(
      ArgumentError,
      /invalid kind/
    )
  end
end
