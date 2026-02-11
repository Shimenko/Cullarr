# frozen_string_literal: true

class Ui::ProgressComponent < Ui::BaseComponent
  VARIANTS = %i[accent success warning danger].freeze

  def initialize(
    value:,
    max: 100,
    label: nil,
    caption: nil,
    animated: false,
    variant: :accent,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @value = normalize_number(name: :value, value: value)
    @max = normalize_number(name: :max, value: max)
    @label = label
    @caption = caption
    @animated = normalized_boolean(name: :animated, value: animated)
    @variant = normalized_option(name: :variant, value: variant, allowed: VARIANTS)

    raise ArgumentError, "#{self.class.name} expects max to be greater than zero." if @max <= 0
  end

  private

  attr_reader :value, :max, :label, :caption, :animated, :variant

  def wrapper_attributes
    html_attributes(
      default_classes: [ "ui-progress" ],
      data: { progress_state: progress_state }
    )
  end

  def track_attributes
    classes = %W[ui-progress-track ui-progress-track-#{variant}]
    classes << "ui-progress-scan" if animated && running?

    {
      class: classes.join(" "),
      value: clamped_value,
      max: max
    }
  end

  def percent
    ((clamped_value / max) * 100).clamp(0, 100).round(2)
  end

  def running?
    percent < 100
  end

  def progress_state
    running? ? "running" : "complete"
  end

  def normalize_number(name:, value:)
    Float(value)
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{self.class.name} expected #{name} to be numeric."
  end

  def clamped_value
    value.clamp(0, max)
  end
end
