# frozen_string_literal: true

class Ui::BaseComponent < ViewComponent::Base
  include Ui::OptionValidation

  def initialize(class_name: nil, data: nil, **html_options)
    @class_name = class_name
    @default_data_attributes = normalize_data_attributes(data)
    @default_html_options = html_options
  end

  private

  attr_reader :class_name, :default_data_attributes, :default_html_options

  def html_attributes(default_classes:, class_name: nil, data: nil, aria: nil, **html_options)
    merged_options = default_html_options.merge(html_options)
    merged_data = normalize_data_attributes(merged_options.delete(:data))
                  .merge(default_data_attributes)
                  .merge(normalize_data_attributes(data))
    merged_aria = normalize_aria_attributes(merged_options.delete(:aria))
                  .merge(normalize_aria_attributes(aria))

    merged_options[:class] = merge_classes(default_classes, self.class_name, class_name, merged_options[:class])
    merged_options[:data] = merged_data if merged_data.any?
    merged_options[:aria] = merged_aria if merged_aria.any?
    merged_options
  end

  def merge_classes(*tokens)
    tokens.flatten.compact.flat_map { |token| token.to_s.split(/\s+/) }.reject(&:empty?).uniq.join(" ")
  end
end
