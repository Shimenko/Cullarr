# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::InputComponent, type: :component do
  def render_component(**kwargs)
    defaults = {
      name: "integration[name]",
      label: "Name",
      value: "Radarr",
      help_text: "Displayed in the dashboard",
      error_text: "Name is required"
    }
    render_inline(described_class.new(**defaults.merge(kwargs)))
  end

  it "renders a label and error styling metadata" do
    fragment = render_component

    input = fragment.css("input").first
    expect(fragment.css("label", text: "Name").size).to eq(1)
    expect(input["aria-invalid"]).to eq("true")
  end

  it "links helper and error ids through aria-describedby" do
    input = render_component.css("input").first

    expect(input["aria-describedby"]).to include("integration_name_help")
    expect(input["aria-describedby"]).to include("integration_name_error")
  end

  it "validates input type" do
    expect { described_class.new(name: "q", type: :date) }.to raise_error(ArgumentError, /invalid type/)
  end
end
