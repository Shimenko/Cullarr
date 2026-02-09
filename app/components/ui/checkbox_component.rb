# frozen_string_literal: true

class Ui::CheckboxComponent < Ui::BaseComponent
  def initialize(
    name:,
    label:,
    checked: false,
    value: "1",
    unchecked_value: "0",
    include_hidden: true,
    id: nil,
    disabled: false,
    help_text: nil,
    class_name: nil,
    data: nil,
    **html_options
  )
    super(class_name:, data:, **html_options)
    @name = name.to_s
    @label = label.to_s
    @checked = normalized_boolean(name: :checked, value: checked)
    @value = value
    @unchecked_value = unchecked_value
    @include_hidden = normalized_boolean(name: :include_hidden, value: include_hidden)
    @id = (id.presence || generated_id)
    @disabled = normalized_boolean(name: :disabled, value: disabled)
    @help_text = help_text
  end

  private

  attr_reader :name, :label, :checked, :value, :unchecked_value, :include_hidden, :id, :disabled, :help_text

  def wrapper_attributes
    html_attributes(default_classes: [ "ui-field" ])
  end

  def input_attributes
    html_attributes(
      default_classes: [ "ui-checkbox-input" ],
      id:,
      type: :checkbox,
      name:,
      value:,
      checked: checked ? true : nil,
      disabled: disabled ? true : nil
    )
  end

  def generated_id
    unique_dom_id(name, suffix: "checkbox")
  end
end
