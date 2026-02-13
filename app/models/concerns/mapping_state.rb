module MappingState
  MAPPING_STATUS_CODES = %w[
    verified_path
    verified_external_ids
    verified_tv_structure
    provisional_title_year
    external_source_not_managed
    unresolved
    ambiguous_conflict
  ].freeze

  MAPPING_STRATEGIES = %w[
    path_match
    external_ids_match
    tv_structure_match
    title_year_fallback
    external_unmanaged_path
    no_match
    conflict_detected
  ].freeze

  def self.included(base)
    base.validates :mapping_status_code, inclusion: { in: MAPPING_STATUS_CODES }
    base.validates :mapping_strategy, inclusion: { in: MAPPING_STRATEGIES }
    base.validate :mapping_diagnostics_json_must_be_hash
  end

  def apply_mapping_state!(status_code:, strategy:, diagnostics:)
    update!(mapping_state_attributes_for(status_code:, strategy:, diagnostics:))
  end

  def mapping_state_attributes_for(status_code:, strategy:, diagnostics:)
    normalized_status = status_code.to_s
    normalized_strategy = strategy.to_s
    normalized_diagnostics = diagnostics.is_a?(Hash) ? diagnostics.deep_stringify_keys : {}

    attrs = {
      mapping_strategy: normalized_strategy,
      mapping_diagnostics_json: normalized_diagnostics
    }

    if mapping_status_code.to_s != normalized_status
      attrs[:mapping_status_code] = normalized_status
      attrs[:mapping_status_changed_at] = Time.current
    end

    attrs
  end

  private

  def mapping_diagnostics_json_must_be_hash
    return if mapping_diagnostics_json.is_a?(Hash)

    errors.add(:mapping_diagnostics_json, "must be an object")
  end
end
