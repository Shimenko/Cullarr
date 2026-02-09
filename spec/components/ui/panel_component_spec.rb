# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::PanelComponent, type: :component do
  it "renders title, subtitle, and body content" do
    fragment = render_inline(described_class.new(title: "Integrations", subtitle: "Configured services")) do
      "Panel body"
    end

    expect(fragment.css("section.ui-panel").size).to eq(1)
    expect(fragment.text).to include("Integrations")
    expect(fragment.text).to include("Configured services")
    expect(fragment.text).to include("Panel body")
  end

  it "supports no padding variant" do
    fragment = render_inline(described_class.new(padding: :none) { "x" })

    expect(fragment.css("section.ui-panel-padding-none").size).to eq(1)
  end
end
