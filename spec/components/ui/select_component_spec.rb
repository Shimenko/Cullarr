# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SelectComponent, type: :component do
  def render_component(**kwargs)
    defaults = {
      name: "integration[kind]",
      label: "Kind",
      options: [ %w[Sonarr sonarr], { label: "Radarr", value: "radarr" } ],
      selected: "radarr",
      include_blank: "Choose"
    }
    render_inline(described_class.new(**defaults.merge(kwargs)))
  end

  it "renders options and selected state" do
    fragment = render_component

    expect(fragment.css("option").map(&:text)).to include("Choose")
    expect(fragment.css("option[selected][value='radarr']").size).to eq(1)
  end

  it "requires options array" do
    expect { described_class.new(name: "kind", options: "invalid") }.to raise_error(
      ArgumentError,
      /expected options to be an array/
    )
  end
end
