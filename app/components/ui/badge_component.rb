# frozen_string_literal: true

class Ui::BadgeComponent < Ui::BaseComponent
  KINDS = %i[neutral success warning danger info].freeze

  def initialize(label: nil, kind: :neutral, icon: nil, class_name: nil, data: nil, **html_options)
    super(class_name:, data:, **html_options)
    @label = label
    @kind = normalized_option(name: :kind, value: kind, allowed: KINDS)
    @icon = icon
  end

  private

  attr_reader :kind, :icon

  def content_text
    content.presence || @label
  end

  def show_icon?
    icon.present?
  end

  def badge_attributes
    html_attributes(default_classes: %W[ui-chip ui-badge ui-badge-#{kind}])
  end
end
