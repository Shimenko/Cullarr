# frozen_string_literal: true

class Ui::SelectComponent < Ui::BaseComponent
  def initialize(
    name:,
    options:,
    label: nil,
    selected: nil,
    include_blank: nil,
    id: nil,
    help_text: nil,
    error_text: nil,
    disabled: false,
    multiple: false,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @name = name.to_s
    @options = normalize_options(options)
    @label = label
    @selected = selected
    @include_blank = include_blank
    @id = (id.presence || generated_id)
    @help_text = help_text
    @error_text = error_text
    @disabled = normalized_boolean(name: :disabled, value: disabled)
    @multiple = normalized_boolean(name: :multiple, value: multiple)
  end

  private

  attr_reader :name, :options, :label, :selected, :include_blank, :id, :help_text, :error_text, :disabled, :multiple

  def wrapper_attributes
    html_attributes(default_classes: [ "ui-field" ])
  end

  def select_attributes
    html_attributes(
      default_classes: [ "ui-control", "ui-select", ("ui-control-invalid" if error_text.present?) ],
      id:,
      name: multiple ? "#{name}[]" : name,
      disabled: disabled ? true : nil,
      multiple: multiple ? true : nil,
      "aria-invalid": error_text.present? ? "true" : nil,
      "aria-describedby": described_by.presence
    )
  end

  def option_selected?(value)
    if multiple
      Array(selected).map(&:to_s).include?(value.to_s)
    else
      selected.to_s == value.to_s
    end
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

  def normalize_options(raw_options)
    raise ArgumentError, "#{self.class.name} expected options to be an array." unless raw_options.is_a?(Array)

    raw_options.map do |raw_option|
      case raw_option
      when Array
        [ raw_option[0].to_s, raw_option[1].to_s ]
      when Hash
        [ raw_option.fetch(:label).to_s, raw_option.fetch(:value).to_s ]
      else
        [ raw_option.to_s, raw_option.to_s ]
      end
    end
  end
end
