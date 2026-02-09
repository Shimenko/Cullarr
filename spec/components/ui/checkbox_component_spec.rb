# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::CheckboxComponent, type: :component do
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
end
