# frozen_string_literal: true

module DatabaseUrlGuard
  module_function

  DB_URL_GROUPS = {
    development: %w[DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL],
    test: %w[TEST_DATABASE_URL TEST_CACHE_DATABASE_URL TEST_QUEUE_DATABASE_URL TEST_CABLE_DATABASE_URL],
    production: %w[
      PRODUCTION_DATABASE_URL
      PRODUCTION_CACHE_DATABASE_URL
      PRODUCTION_QUEUE_DATABASE_URL
      PRODUCTION_CABLE_DATABASE_URL
    ]
  }.freeze

  def validate!
    validate_group_completeness!
    validate_uniqueness!
  end

  def validate_group_completeness!
    DB_URL_GROUPS.each do |group_name, vars|
      next unless vars.any? { |var_name| ENV.key?(var_name) }

      missing = vars.reject { |var_name| configured_value(var_name) }
      next if missing.empty?

      raise ArgumentError,
            "Incomplete #{group_name} database URL group. Set all of: #{vars.join(', ')}. Missing/blank: #{missing.join(', ')}"
    end
  end

  def validate_uniqueness!
    configured_vars = DB_URL_GROUPS.values.flatten.filter_map do |var_name|
      value = configured_value(var_name)
      next unless value

      [ var_name, value ]
    end

    duplicates = configured_vars.group_by { |(_, value)| value }
                              .transform_values { |pairs| pairs.map(&:first) }
                              .select { |_, vars| vars.size > 1 }

    return if duplicates.empty?

    duplicate_details = duplicates.values.map { |vars| vars.join(" = ") }.join("; ")
    raise ArgumentError,
          "Database URLs must be unique across all roles/environments. Duplicates: #{duplicate_details}"
  end

  def configured_value(var_name)
    return nil unless ENV.key?(var_name)

    value = ENV[var_name].to_s.strip
    return nil if value.empty?

    value
  end
end

DatabaseUrlGuard.validate!
