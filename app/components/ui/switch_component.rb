# frozen_string_literal: true

class Ui::SwitchComponent < Ui::BaseComponent
  def initialize(
    name:,
    label:,
    checked: false,
    value: "1",
    unchecked_value: "0",
    include_hidden: true,
    id: nil,
    disabled: false,
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
  end

  private

  attr_reader :name, :label, :checked, :value, :unchecked_value, :include_hidden, :id, :disabled

  def wrapper_attributes
    html_attributes(default_classes: [ "ui-field" ])
  end

  def input_attributes
    html_attributes(
      default_classes: [ "ui-switch-input" ],
      id:,
      type: :checkbox,
      role: :switch,
      name:,
      value:,
      checked: checked ? true : nil,
      disabled: disabled ? true : nil
    )
  end

  def generated_id
    "#{name.downcase.gsub(/[^a-z0-9]+/, "_")}_switch"
  end
end
