# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::SwitchComponent, type: :component do
  def render_repeated_switches
    first_html = render_inline(
      described_class.new(name: "settings[cache]", label: "Cache images")
    ).to_html
    second_html = render_inline(
      described_class.new(name: "settings[cache]", label: "Cache images")
    ).to_html
    fragment = Capybara.string("#{first_html}#{second_html}")
    switches = fragment.all("input[type='checkbox'][role='switch']")
    labels = fragment.all("label.ui-switch")

    [ switches, labels ]
  end

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

  it "generates unique ids for repeated controls with the same name" do
    switches, labels = render_repeated_switches
    switch_ids = switches.map { |element| element["id"] }

    expect(switch_ids.uniq.size).to eq(2)
    expect(labels.map { |label| label["for"] }).to match_array(switch_ids)
  end

  it "respects explicit ids" do
    fragment = render_inline(
      described_class.new(name: "settings[cache]", label: "Cache images", id: "custom-switch-id")
    )
    switch = fragment.css("input[type='checkbox'][role='switch']").first
    label = fragment.css("label.ui-switch").first

    expect(switch["id"]).to eq("custom-switch-id")
    expect(label["for"]).to eq("custom-switch-id")
  end
end
