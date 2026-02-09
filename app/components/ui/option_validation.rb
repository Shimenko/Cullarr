# frozen_string_literal: true

module Ui
  module OptionValidation
    private

    def normalized_option(name:, value:, allowed:)
      allowed_values = allowed.map(&:to_s)
      normalized_value = value.to_s

      return normalized_value.to_sym if allowed_values.include?(normalized_value)

      raise ArgumentError, "#{self.class.name} received invalid #{name}: #{value.inspect}. " \
                           "Allowed values: #{allowed_values.join(', ')}."
    end

    def normalized_boolean(name:, value:)
      return value if value == true || value == false

      raise ArgumentError, "#{self.class.name} expected #{name} to be true or false."
    end

    def normalize_data_attributes(data)
      return {} if data.nil?

      raise ArgumentError, "#{self.class.name} expected data to be a hash." unless data.is_a?(Hash)

      data.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_sym] = value
      end
    end

    def normalize_aria_attributes(aria)
      return {} if aria.nil?

      raise ArgumentError, "#{self.class.name} expected aria to be a hash." unless aria.is_a?(Hash)

      aria.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_sym] = value
      end
    end
  end
end
