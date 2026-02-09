# frozen_string_literal: true

class Ui::ButtonComponent < Ui::BaseComponent
  VARIANTS = %i[primary secondary ghost danger link].freeze
  SIZES = %i[sm md lg].freeze
  TYPES = %i[button submit reset].freeze
  ICON_POSITIONS = %i[leading trailing].freeze

  def initialize(
    label: nil,
    variant: :primary,
    size: :md,
    type: :button,
    disabled: false,
    href: nil,
    icon: nil,
    icon_position: :leading,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @label = label
    @variant = normalized_option(name: :variant, value: variant, allowed: VARIANTS)
    @size = normalized_option(name: :size, value: size, allowed: SIZES)
    @disabled = normalized_boolean(name: :disabled, value: disabled)
    @icon = icon
    @icon_position = normalized_option(name: :icon_position, value: icon_position, allowed: ICON_POSITIONS)
    @href = href
    @type = normalized_option(name: :type, value: type, allowed: TYPES)
  end

  private

  attr_reader :variant, :size, :disabled, :icon, :icon_position, :href, :type

  def button_attributes
    base_attributes = html_attributes(
      default_classes: %W[ui-button ui-button-#{variant} ui-button-#{size} ui-motion ui-motion-lift],
      aria: disabled && href.present? ? { disabled: "true" } : {}
    )

    if href.present?
      base_attributes.merge(href: disabled ? nil : href, tabindex: disabled ? "-1" : nil)
    else
      base_attributes.merge(type:, disabled: disabled ? true : nil)
    end
  end

  def icon_name
    icon.presence
  end

  def icon_size
    size == :lg ? :md : :sm
  end

  def content_text
    content.presence || @label
  end

  def show_icon?
    icon_name.present?
  end

  def leading_icon?
    icon_position == :leading
  end

  def trailing_icon?
    icon_position == :trailing
  end
end
