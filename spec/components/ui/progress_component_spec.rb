# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ProgressComponent, type: :component do
  it "renders progress metadata and animated fill" do
    fragment = render_inline(
      described_class.new(value: 45, max: 120, label: "Sync", caption: "45 / 120", animated: true)
    )

    expect(fragment.css("span.ui-progress-label", text: "Sync").size).to eq(1)
    expect(fragment.css("span.ui-progress-fill.ui-progress-scan").size).to eq(1)
    expect(fragment.css("span.ui-progress-caption", text: "45 / 120").size).to eq(1)
  end

  it "rejects non-positive max" do
    expect { described_class.new(value: 0, max: 0) }.to raise_error(
      ArgumentError,
      /max to be greater than zero/
    )
  end
end
