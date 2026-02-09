# frozen_string_literal: true

class Ui::PanelComponent < Ui::BaseComponent
  PADDINGS = %i[none sm md lg].freeze

  def initialize(title: nil, subtitle: nil, padding: :md, class_name: nil, data: nil, **html_options)
    super(class_name:, data:, **html_options)
    @title = title
    @subtitle = subtitle
    @padding = normalized_option(name: :padding, value: padding, allowed: PADDINGS)
  end

  private

  attr_reader :title, :subtitle, :padding

  def panel_attributes
    html_attributes(default_classes: %W[ui-panel ui-panel-padding-#{padding}])
  end

  def show_header?
    title.present? || subtitle.present?
  end
end
