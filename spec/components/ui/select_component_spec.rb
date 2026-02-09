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

  def repeated_select_artifacts
    first_html = render_component(help_text: "First help", error_text: "First error").to_html
    second_html = render_component(help_text: "Second help", error_text: "Second error").to_html
    fragment = Capybara.string("#{first_html}#{second_html}")
    selects = fragment.all("select")
    labels = fragment.all("label")

    [ fragment, selects, labels ]
  end

  def expect_select_described_by_to_match_ids(fragment, selects)
    selects.each do |select|
      select_id = select["id"]
      described_by_ids = select["aria-describedby"].to_s.split

      expect(described_by_ids).to contain_exactly("#{select_id}_help", "#{select_id}_error")
      expect(fragment).to have_css("##{select_id}_help")
      expect(fragment).to have_css("##{select_id}_error")
    end
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

  it "generates unique ids for repeated controls with the same name" do
    fragment, selects, labels = repeated_select_artifacts
    select_ids = selects.map { |element| element["id"] }

    expect(select_ids.uniq.size).to eq(2)
    expect(labels.map { |label| label["for"] }).to match_array(select_ids)
    expect_select_described_by_to_match_ids(fragment, selects)
  end

  it "respects explicit ids and keeps helper/error ids aligned" do
    fragment = render_component(
      id: "custom-select-id",
      help_text: "Select help",
      error_text: "Select error"
    )
    select = fragment.css("select").first

    expect(select["id"]).to eq("custom-select-id")
    expect(select["aria-describedby"]).to include("custom-select-id_help")
    expect(select["aria-describedby"]).to include("custom-select-id_error")
    expect(fragment.css("label").first["for"]).to eq("custom-select-id")
  end
end
