# frozen_string_literal: true

class Ui::IconButtonComponent < Ui::BaseComponent
  VARIANTS = %i[secondary ghost danger].freeze
  SIZES = %i[sm md lg].freeze
  TYPES = %i[button submit reset].freeze

  def initialize(
    icon:,
    aria_label:,
    variant: :secondary,
    size: :md,
    type: :button,
    disabled: false,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @icon = icon
    @aria_label = aria_label.to_s
    @variant = normalized_option(name: :variant, value: variant, allowed: VARIANTS)
    @size = normalized_option(name: :size, value: size, allowed: SIZES)
    @type = normalized_option(name: :type, value: type, allowed: TYPES)
    @disabled = normalized_boolean(name: :disabled, value: disabled)

    raise ArgumentError, "#{self.class.name} requires aria_label." if @aria_label.blank?
  end

  private

  attr_reader :icon, :variant, :size, :type, :disabled, :aria_label

  def icon_size
    size == :lg ? :md : :sm
  end

  def button_attributes
    html_attributes(
      default_classes: %W[ui-button ui-button-#{variant} ui-button-#{size} ui-icon-button ui-motion ui-motion-lift],
      type:,
      disabled: disabled ? true : nil,
      "aria-label": aria_label
    )
  end
end
