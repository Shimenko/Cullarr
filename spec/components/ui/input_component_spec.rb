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
    input_id = input["id"]

    expect(input["aria-describedby"]).to include("#{input_id}_help")
    expect(input["aria-describedby"]).to include("#{input_id}_error")
  end

  it "generates unique ids for repeated controls with the same name" do
    first_html = render_component(error_text: nil, help_text: nil).to_html
    second_html = render_component(error_text: nil, help_text: nil).to_html
    fragment = Capybara.string("#{first_html}#{second_html}")

    inputs = fragment.all("input")
    labels = fragment.all("label")
    input_ids = inputs.map { |input| input["id"] }

    expect(input_ids.uniq.size).to eq(2)
    expect(labels.map { |label| label["for"] }).to match_array(input_ids)
  end

  it "respects explicit ids and keeps helper/error ids aligned" do
    fragment = render_component(id: "custom-input-id")
    input = fragment.css("input").first

    expect(input["id"]).to eq("custom-input-id")
    expect(input["aria-describedby"]).to include("custom-input-id_help")
    expect(input["aria-describedby"]).to include("custom-input-id_error")
    expect(fragment.css("label").first["for"]).to eq("custom-input-id")
  end

  it "validates input type" do
    expect { described_class.new(name: "q", type: :date) }.to raise_error(ArgumentError, /invalid type/)
  end
end
