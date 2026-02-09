# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SwitchComponent, type: :component do
  it "renders switch semantics and checked state" do
    fragment = render_inline(described_class.new(name: "settings[cache]", label: "Cache images", checked: true))

    expect(fragment.css("input[type='checkbox'][role='switch'][checked]").size).to eq(1)
    expect(fragment.css("span.ui-switch-track").size).to eq(1)
  end

  it "validates boolean checked values" do
    expect { described_class.new(name: "settings[cache]", label: "Cache", checked: "yes") }.to raise_error(
      ArgumentError,
      /checked to be true or false/
    )
  end
end
