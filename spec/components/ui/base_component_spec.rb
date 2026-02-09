# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::BaseComponent, type: :component do
  let(:component_class) do
    stub_const("SpecUiBaseTestComponent", Class.new(described_class) do
      def initialize(variant: :primary, enabled: true, class_name: nil, data: nil, **html_options)
        super(class_name:, data:, **html_options)
        @variant = normalized_option(name: :variant, value: variant, allowed: %i[primary secondary])
        @enabled = normalized_boolean(name: :enabled, value: enabled)
      end

      def call
        tag.button(
          "Cull",
          **html_attributes(
            default_classes: %W[ui-button ui-button-#{@variant}],
            data: { component: "ui-test-button" },
            disabled: !@enabled
          )
        )
      end
    end)
  end

  def rendered_button(**kwargs)
    render_inline(component_class.new(**kwargs)).css("button").first
  end

  it "composes default classes with caller-provided classes" do
    button = rendered_button(class_name: "custom-class")

    expect(button["class"]).to include("ui-button")
    expect(button["class"]).to include("ui-button-primary")
    expect(button["class"]).to include("custom-class")
  end

  it "merges html options and data attributes" do
    button = rendered_button(data: { action: "click->ui#run" }, id: "delete-btn")

    expect(button["id"]).to eq("delete-btn")
    expect(button["data-action"]).to eq("click->ui#run")
    expect(button["data-component"]).to eq("ui-test-button")
    expect(button["disabled"]).to be_nil
  end

  it "raises when a variant is outside the component contract" do
    expect { component_class.new(variant: :dangerous) }.to raise_error(
      ArgumentError,
      /invalid variant/
    )
  end

  it "raises when data attributes are not a hash" do
    expect { component_class.new(data: "invalid") }.to raise_error(
      ArgumentError,
      /data to be a hash/
    )
  end

  it "raises when boolean arguments are not true or false" do
    expect { component_class.new(enabled: "yes") }.to raise_error(
      ArgumentError,
      /enabled to be true or false/
    )
  end
end
