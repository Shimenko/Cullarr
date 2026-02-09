# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::BadgeComponent, type: :component do
  it "renders badge with default kind" do
    fragment = render_inline(described_class.new(label: "Queued"))
    badge = fragment.css("span.ui-badge").first

    expect(badge["class"]).to include("ui-badge-neutral")
    expect(badge.text).to include("Queued")
  end

  it "validates allowed kinds" do
    expect { described_class.new(label: "Bad", kind: :instance) }.to raise_error(
      ArgumentError,
      /invalid kind/
    )
  end
end
