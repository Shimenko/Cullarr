# frozen_string_literal: true

class Ui::InputComponent < Ui::BaseComponent
  TYPES = %i[text email password search number url tel].freeze

  def initialize(
    name:,
    label: nil,
    value: nil,
    type: :text,
    id: nil,
    placeholder: nil,
    help_text: nil,
    error_text: nil,
    required: false,
    disabled: false,
    autocomplete: nil,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @name = name.to_s
    @label = label
    @value = value
    @type = normalized_option(name: :type, value: type, allowed: TYPES)
    @id = (id.presence || generated_id)
    @placeholder = placeholder
    @help_text = help_text
    @error_text = error_text
    @required = normalized_boolean(name: :required, value: required)
    @disabled = normalized_boolean(name: :disabled, value: disabled)
    @autocomplete = autocomplete
  end

  private

  attr_reader :name, :label, :value, :type, :id, :placeholder, :help_text, :error_text, :required, :disabled,
              :autocomplete

  def wrapper_attributes
    html_attributes(default_classes: [ "ui-field" ])
  end

  def input_attributes
    html_attributes(
      default_classes: [ "ui-control", ("ui-control-invalid" if error_text.present?) ],
      id:,
      name:,
      type:,
      value:,
      placeholder:,
      required: required ? true : nil,
      disabled: disabled ? true : nil,
      autocomplete:,
      "aria-invalid": error_text.present? ? "true" : nil,
      "aria-describedby": described_by.presence
    )
  end

  def described_by
    values = []
    values << help_id if help_text.present?
    values << error_id if error_text.present?
    values.join(" ")
  end

  def help_id
    "#{id}_help"
  end

  def error_id
    "#{id}_error"
  end

  def generated_id
    name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  end
end
