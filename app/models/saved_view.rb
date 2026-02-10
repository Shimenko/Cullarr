class SavedView < ApplicationRecord
  SCOPES = %w[movie tv_show tv_season tv_episode].freeze
  ALLOWED_FILTER_KEYS = %w[plex_user_ids include_blocked].freeze

  before_validation :normalize_name
  before_validation :normalize_filters_json

  validates :name, :scope, presence: true
  validates :name, uniqueness: true
  validates :scope, inclusion: { in: SCOPES }
  validate :filters_json_must_be_supported_hash
  validate :filters_json_values_must_match_schema

  def as_api_json
    {
      id: id,
      name: name,
      scope: scope,
      filters: filters_json,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  private

  def normalize_name
    self.name = name.to_s.strip
  end

  def normalize_filters_json
    normalized_value = case filters_json
    when nil
      {}
    when ActionController::Parameters
      filters_json.to_unsafe_h
    when Hash
      filters_json
    else
      filters_json
    end

    self.filters_json = normalized_value.is_a?(Hash) ? normalized_value.deep_stringify_keys : normalized_value
  end

  def filters_json_must_be_supported_hash
    unless filters_json.is_a?(Hash)
      errors.add(:filters_json, "must be an object")
      return
    end

    unsupported_keys = filters_json.keys - ALLOWED_FILTER_KEYS
    if unsupported_keys.any?
      errors.add(:filters_json, "contains unsupported keys: #{unsupported_keys.join(', ')}")
    end
  end

  def filters_json_values_must_match_schema
    return unless filters_json.is_a?(Hash)

    validate_plex_user_ids_filter
    validate_include_blocked_filter
  end

  def validate_plex_user_ids_filter
    return unless filters_json.key?("plex_user_ids")

    value = filters_json["plex_user_ids"]
    valid = value.is_a?(Array) && value.all? { |entry| entry.is_a?(Integer) && entry.positive? }
    return if valid

    errors.add("filters.plex_user_ids", "must be an array of positive integers")
  end

  def validate_include_blocked_filter
    return unless filters_json.key?("include_blocked")

    value = filters_json["include_blocked"]
    return if value == true || value == false

    errors.add("filters.include_blocked", "must be true or false")
  end
end
