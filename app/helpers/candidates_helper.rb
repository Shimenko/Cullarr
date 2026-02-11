module CandidatesHelper
  SCOPE_OPTIONS = [
    [ "Movies", "movie" ],
    [ "TV Show", "tv_show" ],
    [ "TV Season", "tv_season" ],
    [ "TV Episode", "tv_episode" ]
  ].freeze

  SCOPE_LABELS = SCOPE_OPTIONS.to_h { |label, value| [ value, label ] }.freeze
  WATCHED_MATCH_MODE_OPTIONS = [
    [ "No selected users watched", "none" ],
    [ "All selected users (strict)", "all" ],
    [ "Any selected user", "any" ]
  ].freeze
  WATCHED_MATCH_MODE_LABELS = WATCHED_MATCH_MODE_OPTIONS.to_h { |label, value| [ value, label ] }.freeze

  FLAG_LABELS = {
    "path_excluded" => "Excluded Path",
    "keep_marked" => "Keep Marked",
    "in_progress_any" => "In Progress",
    "ambiguous_mapping" => "Conflicting Plex Matches",
    "ambiguous_ownership" => "File Claimed by Multiple Libraries",
    "rollup_not_strictly_eligible" => "Strict Rollup Block",
    "multiple_versions" => "Multiple Versions",
    "no_plex_mapping" => "Found in Sonarr/Radarr, not linked in Plex",
    "external_id_mismatch" => "Plex ID Conflict",
    "low_confidence_mapping" => "Linked by IDs Only"
  }.freeze

  BLOCKER_HINTS = {
    "path_excluded" => "Path exclusion rule blocks deletion for this item.",
    "keep_marked" => "A keep marker blocks deletion for this item.",
    "in_progress_any" => "At least one selected Plex user is currently in progress.",
    "ambiguous_mapping" => "Plex identifiers point to conflicting matches and deletion is blocked until resolved.",
    "ambiguous_ownership" => "More than one integration claims the same canonical file path.",
    "rollup_not_strictly_eligible" => "Show or season rollup is not fully eligible."
  }.freeze

  MAPPING_STATUS_LABELS = {
    "mapped_linked_in_plex" => "Mapped: Linked in Plex",
    "mapped_linked_by_external_ids" => "Mapped: Linked by external IDs (review recommended)",
    "needs_review_conflicting_plex_matches" => "Needs review: Multiple possible Plex matches",
    "needs_review_plex_id_conflict" => "Needs review: Plex identifiers conflict",
    "unmapped_check_path_mapping_between_arr_and_plex" => "Unmapped: Path mismatch between ARR and Plex",
    "unmapped_plex_data_missing_identifiers" => "Unmapped: Plex data missing path/IDs",
    "unmapped_found_in_arr_not_linked_in_plex" => "Unmapped: Found in Sonarr/Radarr, not in Plex scan",
    "rollup_mapped_linked_in_plex" => "Mapped: All episodes linked in Plex",
    "rollup_mapped_with_external_id_links" => "Mapped: Some episodes linked by external IDs",
    "rollup_unmapped_contains_unlinked_items" => "Unmapped: Rollup includes unlinked episodes",
    "rollup_needs_review_contains_conflicts" => "Needs review: Rollup includes mapping conflicts"
  }.freeze

  MAPPING_STATUS_HINTS = {
    "mapped_linked_in_plex" => "Identity mapping is stable and linked by Plex key.",
    "mapped_linked_by_external_ids" => "Linked through external IDs. Verify path mapping for stronger confidence.",
    "needs_review_conflicting_plex_matches" => "Multiple candidates matched the same Plex identity. Resolve before deletion.",
    "needs_review_plex_id_conflict" => "External IDs disagree with existing Plex identity metadata.",
    "unmapped_check_path_mapping_between_arr_and_plex" => "Configure ARR-to-Plex path mapping (for example /storage/... -> /home/... ).",
    "unmapped_plex_data_missing_identifiers" => "Tautulli/Plex did not provide enough path or external-ID data to match.",
    "unmapped_found_in_arr_not_linked_in_plex" => "Item exists in Sonarr/Radarr but was not seen in Plex/Tautulli library mapping.",
    "rollup_mapped_linked_in_plex" => "Every episode in this rollup is mapped to Plex.",
    "rollup_mapped_with_external_id_links" => "Rollup is mapped, but some episodes rely on external-ID fallback matching.",
    "rollup_unmapped_contains_unlinked_items" => "At least one episode is not linked to Plex yet.",
    "rollup_needs_review_contains_conflicts" => "At least one episode has mapping conflicts that require review."
  }.freeze

  HIDDEN_MAPPING_RISK_FLAGS = %w[
    no_plex_mapping
    low_confidence_mapping
    external_id_mismatch
  ].freeze

  def candidate_scope_options
    SCOPE_OPTIONS
  end

  def candidate_scope_label(scope)
    SCOPE_LABELS.fetch(scope.to_s, scope.to_s.humanize)
  end

  def candidate_watched_match_mode_options
    WATCHED_MATCH_MODE_OPTIONS
  end

  def candidate_watched_match_mode_label(mode)
    WATCHED_MATCH_MODE_LABELS.fetch(mode.to_s, mode.to_s.humanize)
  end

  def candidate_flag_label(flag)
    FLAG_LABELS.fetch(flag.to_s, flag.to_s.humanize)
  end

  def candidate_blocker_hint(flag)
    BLOCKER_HINTS[flag.to_s]
  end

  def candidate_mapping_status_label(mapping_status_code)
    MAPPING_STATUS_LABELS.fetch(mapping_status_code.to_s, mapping_status_code.to_s.humanize)
  end

  def candidate_mapping_status_hint(mapping_status_code)
    MAPPING_STATUS_HINTS[mapping_status_code.to_s]
  end

  def candidate_mapping_status_chip_kind(mapping_status_state)
    case mapping_status_state.to_s
    when "mapped"
      :success
    when "needs_review"
      :blocker
    else
      :warning
    end
  end

  def candidate_display_risk_flags(risk_flags)
    Array(risk_flags).reject { |flag| HIDDEN_MAPPING_RISK_FLAGS.include?(flag) }
  end

  def candidate_reason_label(reason)
    key, value = reason.to_s.split(":", 2)

    case key
    when "watched_by_all_selected_users"
      "Watched by all selected users"
    when "last_watched_days_ago"
      "Last watched #{value} day(s) ago"
    when "added_days_ago"
      "Added #{value} day(s) ago"
    when "reclaims_gb"
      "Reclaims #{value} GB"
    else
      reason.to_s.humanize
    end
  end

  def candidate_watched_summary_text(watched_summary)
    selected_count = watched_summary[:selected_user_count].to_i
    watched_count = watched_summary[:watched_user_count].to_i
    last_watched_at = watched_summary[:last_watched_at]

    summary = "#{watched_count}/#{selected_count} selected user(s) watched"
    return summary if last_watched_at.blank?

    "#{summary}. Last watched #{time_ago_in_words(last_watched_at)} ago."
  end

  def candidate_selection_id(item)
    scope = item[:scope].to_s

    case scope
    when "movie"
      item[:movie_id]
    when "tv_episode"
      item[:episode_id]
    when "tv_season"
      item[:season_id]
    when "tv_show"
      item[:series_id]
    end
  end

  def candidate_selection_key(scope)
    case scope.to_s
    when "movie"
      "movie_ids"
    when "tv_episode"
      "episode_ids"
    when "tv_season"
      "season_ids"
    when "tv_show"
      "series_ids"
    end
  end

  def candidate_group_label(group_key)
    if group_key.start_with?("movie:")
      "Movie versions"
    elsif group_key.start_with?("episode:")
      "Episode versions (#{group_key})"
    else
      "Version group #{group_key}"
    end
  end
end
