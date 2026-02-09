# frozen_string_literal: true

require "base64"

module ActiveRecordEncryptionConfig
  module_function

  PRIMARY_KEYS_ENV = "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEYS"
  DETERMINISTIC_KEY_ENV = "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"
  KEY_DERIVATION_SALT_ENV = "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"

  def configure!(config:, env: ENV)
    primary_keys, deterministic_key, key_derivation_salt = resolve_keys(env:)

    config.active_record.encryption.primary_key = primary_keys
    config.active_record.encryption.deterministic_key = deterministic_key
    config.active_record.encryption.key_derivation_salt = key_derivation_salt
    config.active_record.encryption.store_key_references = true
  end

  def resolve_keys(env:)
    primary_keys = csv_values(env[PRIMARY_KEYS_ENV])
    deterministic_key = env[DETERMINISTIC_KEY_ENV].to_s.strip
    key_derivation_salt = env[KEY_DERIVATION_SALT_ENV].to_s.strip

    if primary_keys.present? && deterministic_key.present? && key_derivation_salt.present?
      return [ primary_keys, deterministic_key, key_derivation_salt ]
    end

    raise_missing_keys! if Rails.env.production?

    fallback_keys
  end

  def csv_values(value)
    value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def fallback_keys
    base_secret = Rails.application.secret_key_base.to_s.presence || "cullarr-dev-active-record-encryption"
    key_generator = ActiveSupport::KeyGenerator.new(base_secret)

    [
      [ Base64.strict_encode64(key_generator.generate_key("active_record_encryption_primary_key", 32)) ],
      Base64.strict_encode64(key_generator.generate_key("active_record_encryption_deterministic_key", 32)),
      Base64.strict_encode64(key_generator.generate_key("active_record_encryption_key_derivation_salt", 32))
    ]
  end

  def raise_missing_keys!
    raise ArgumentError,
          "Missing Active Record encryption keys. Set #{PRIMARY_KEYS_ENV}, #{DETERMINISTIC_KEY_ENV}, and #{KEY_DERIVATION_SALT_ENV}."
  end
end

ActiveRecordEncryptionConfig.configure!(config: Rails.application.config)
