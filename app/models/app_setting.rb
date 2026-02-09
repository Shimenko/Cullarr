class AppSetting < ApplicationRecord
  class InvalidSettingError < StandardError
    attr_reader :details

    def initialize(details)
      @details = details
      super("settings validation failed")
    end
  end

  class ImmutableSettingError < StandardError
    attr_reader :keys

    def initialize(keys)
      @keys = keys
      super("immutable settings cannot be changed")
    end
  end

  class UnsafeSettingError < StandardError
    attr_reader :details

    def initialize(details)
      @details = details
      super("unsafe setting update requires explicit confirmation")
    end
  end

  BOOLEAN_TRUE_VALUES = [ true, 1, "1", "true", "TRUE", "on" ].freeze
  BOOLEAN_FALSE_VALUES = [ false, 0, "0", "false", "FALSE", "off" ].freeze

  DB_DEFINITIONS = {
    "sync_enabled" => { type: :boolean, default: true },
    "sync_interval_minutes" => { type: :integer, default: 30, min: 1, max: 1440 },
    "watched_mode" => { type: :enum, default: "play_count", allowed: %w[play_count percent] },
    "watched_percent_threshold" => { type: :integer, default: 90, min: 1, max: 100 },
    "in_progress_min_offset_ms" => { type: :integer, default: 1, min: 1, max: 86_400_000 },
    "culled_tag_name" => { type: :string, default: "cullarr:culled", max_length: 128 },
    "image_cache_enabled" => { type: :boolean, default: false },
    "compatibility_mode_default" => {
      type: :enum,
      default: "strict_latest",
      allowed: %w[strict_latest warn_only_read_only]
    },
    "unmonitor_mode" => { type: :enum, default: "selected_scope", allowed: %w[selected_scope] },
    "unmonitor_parent_on_partial_version_delete" => { type: :boolean, default: false },
    "retention_sync_runs_days" => { type: :integer, default: 180, min: 1, max: 3650 },
    "retention_deletion_runs_days" => { type: :integer, default: 730, min: 1, max: 3650 },
    "retention_audit_events_days" => { type: :integer, default: 0, min: 0, max: 36_500 },
    "image_proxy_timeout_seconds" => { type: :integer, default: 10, min: 1, max: 120 },
    "image_proxy_max_bytes" => { type: :integer, default: 5_242_880, min: 65_536, max: 52_428_800 },
    "sensitive_action_reauthentication_window_minutes" => {
      type: :integer,
      default: 15,
      min: 1,
      max: 1440
    }
  }.freeze

  ENV_DEFINITIONS = {
    "delete_mode_enabled" => { type: :boolean, env_key: "CULLARR_DELETE_MODE_ENABLED", default: false },
    "delete_mode_secret_present" => {
      type: :presence_boolean,
      env_key: "CULLARR_DELETE_MODE_SECRET",
      default: false
    },
    "image_proxy_allowed_hosts" => { type: :csv, env_key: "CULLARR_IMAGE_PROXY_ALLOWED_HOSTS", default: [] },
    "integration_allowed_hosts" => { type: :csv, env_key: "CULLARR_ALLOWED_INTEGRATION_HOSTS", default: [] },
    "integration_allowed_network_ranges" => {
      type: :csv,
      env_key: "CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES",
      default: []
    }
  }.freeze

  validates :key, presence: true, uniqueness: true

  class << self
    def db_keys
      DB_DEFINITIONS.keys
    end

    def db_default_for(key)
      DB_DEFINITIONS.fetch(key).fetch(:default)
    end

    def db_value_for(key)
      find_by(key: key)&.value_json || db_default_for(key)
    end

    def immutable_keys
      ENV_DEFINITIONS.keys
    end

    def ensure_defaults!
      DB_DEFINITIONS.each do |key, definition|
        find_or_create_by!(key: key) do |setting|
          setting.value_json = definition[:default]
        end
      end
    end

    def effective_settings(env: ENV)
      settings = effective_db_settings
      ENV_DEFINITIONS.each do |key, definition|
        settings[key] = effective_env_setting(definition, env:)
      end
      settings
    end

    def apply_updates!(settings:, destructive_confirmations: {})
      normalized_input = normalize_input(settings)
      immutable_requested = normalized_input.keys & immutable_keys
      raise ImmutableSettingError.new(immutable_requested) if immutable_requested.any?

      unknown_keys = normalized_input.keys - db_keys
      if unknown_keys.any?
        raise InvalidSettingError.new(fields: { settings: [ "unknown keys: #{unknown_keys.join(', ')}" ] })
      end

      current_records = where(key: normalized_input.keys).index_by(&:key)
      changed_values = {}
      field_errors = {}

      normalized_input.each do |key, value|
        definition = DB_DEFINITIONS.fetch(key)
        casted_value = cast_value(value, definition, key:)
        current_value = current_records[key]&.value_json
        current_value = definition[:default] if current_value.nil?
        next if current_value == casted_value

        changed_values[key] = { old: current_value, new: casted_value }
      rescue InvalidSettingError => e
        field_errors.merge!(e.details.fetch(:fields, {}))
      end

      raise InvalidSettingError.new(fields: field_errors) if field_errors.any?
      validate_destructive_confirmations!(changed_values, destructive_confirmations)

      transaction do
        changed_values.each do |key, change|
          setting = current_records[key] || new(key:)
          setting.value_json = change[:new]
          setting.save!
        end
      end

      changed_values
    end

    private

    def effective_db_settings
      records_by_key = where(key: db_keys).index_by(&:key)

      DB_DEFINITIONS.each_with_object({}) do |(key, definition), settings|
        if records_by_key[key]
          settings[key] = { value: records_by_key[key].value_json, source: "db" }
        else
          settings[key] = { value: definition[:default], source: "default" }
        end
      end
    end

    def effective_env_setting(definition, env:)
      raw_value = env[definition.fetch(:env_key)]
      return { value: definition[:default], source: "default" } if raw_value.blank?

      value = case definition.fetch(:type)
      when :boolean
        cast_boolean(raw_value, key: definition.fetch(:env_key))
      when :presence_boolean
        raw_value.present?
      when :csv
        raw_value.to_s.split(",").map(&:strip).reject(&:blank?)
      else
        definition[:default]
      end

      { value:, source: "env" }
    rescue InvalidSettingError
      { value: definition[:default], source: "default" }
    end

    def normalize_input(settings)
      return settings.to_h.stringify_keys if settings.respond_to?(:to_h)

      raise InvalidSettingError.new(fields: { settings: [ "must be an object" ] })
    end

    def cast_value(value, definition, key:)
      case definition.fetch(:type)
      when :boolean
        cast_boolean(value, key:)
      when :integer
        cast_integer(value, definition, key:)
      when :enum
        cast_enum(value, definition, key:)
      when :string
        cast_string(value, definition, key:)
      else
        raise InvalidSettingError.new(fields: { key => [ "has unsupported setting type" ] })
      end
    end

    def cast_boolean(value, key:)
      return true if BOOLEAN_TRUE_VALUES.include?(value)
      return false if BOOLEAN_FALSE_VALUES.include?(value)

      raise InvalidSettingError.new(fields: { key => [ "must be a boolean" ] })
    end

    def cast_integer(value, definition, key:)
      integer_value = Integer(value, exception: false)
      raise InvalidSettingError.new(fields: { key => [ "must be an integer" ] }) if integer_value.nil?

      min = definition[:min]
      max = definition[:max]
      if min && integer_value < min
        raise InvalidSettingError.new(fields: { key => [ "must be greater than or equal to #{min}" ] })
      end

      if max && integer_value > max
        raise InvalidSettingError.new(fields: { key => [ "must be less than or equal to #{max}" ] })
      end

      integer_value
    end

    def cast_enum(value, definition, key:)
      string_value = value.to_s
      allowed_values = definition.fetch(:allowed)
      return string_value if allowed_values.include?(string_value)

      raise InvalidSettingError.new(fields: { key => [ "must be one of: #{allowed_values.join(', ')}" ] })
    end

    def cast_string(value, definition, key:)
      string_value = value.to_s.strip
      raise InvalidSettingError.new(fields: { key => [ "must be present" ] }) if string_value.blank?

      max_length = definition[:max_length]
      if max_length && string_value.length > max_length
        raise InvalidSettingError.new(fields: { key => [ "must be #{max_length} characters or fewer" ] })
      end

      string_value
    end

    def validate_destructive_confirmations!(changed_values, confirmations)
      return unless changed_values.dig("retention_audit_events_days", :new) == 0
      return if truthy?(confirmations&.to_h&.with_indifferent_access&.dig(:retention_audit_events_days_zero))

      raise UnsafeSettingError.new(
        fields: {
          retention_audit_events_days: [ "setting to 0 requires explicit confirmation" ]
        }
      )
    end

    def truthy?(value)
      BOOLEAN_TRUE_VALUES.include?(value)
    end
  end
end
