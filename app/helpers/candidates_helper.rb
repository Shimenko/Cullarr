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
    "no_plex_mapping" => "Found in Sonarr/Radarr, not linked in Plex"
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
    "verified_path" => "Verified by path",
    "verified_external_ids" => "Verified by external IDs",
    "verified_tv_structure" => "Verified by TV structure",
    "provisional_title_year" => "Provisional title/year match",
    "external_source_not_managed" => "External source not managed",
    "unresolved" => "Unresolved mapping",
    "ambiguous_conflict" => "Ambiguous conflict"
  }.freeze

  MAPPING_STATUS_HINTS = {
    "verified_path" => "Path-based verification passed.",
    "verified_external_ids" => "External ID verification passed.",
    "verified_tv_structure" => "TV structure verification passed.",
    "provisional_title_year" => "This match is provisional until a stronger recheck confirms it.",
    "external_source_not_managed" => "The mapped file path is outside managed roots.",
    "unresolved" => "No strong mapping signal produced a verified match.",
    "ambiguous_conflict" => "Conflicting strong signals were detected."
  }.freeze

  MAPPING_STATUS_NEXT_ACTIONS = {
    "verified_path" => "No action needed.",
    "verified_external_ids" => "Spot-check IDs if this match looks unexpected.",
    "verified_tv_structure" => "Spot-check show/season/episode linkage.",
    "provisional_title_year" => "Run sync recheck and verify IDs before deletion.",
    "external_source_not_managed" => "Review managed path roots and path mappings if this should be ARR-owned.",
    "unresolved" => "Check path mappings and external IDs, then rerun sync.",
    "ambiguous_conflict" => "Resolve source conflict before deletion."
  }.freeze

  HIDDEN_MAPPING_RISK_FLAGS = %w[
    no_plex_mapping
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
    when "verified"
      :success
    when "ambiguous"
      :blocker
    when "external"
      :info
    else
      :warning
    end
  end

  def candidate_mapping_status_next_action(mapping_status_code)
    MAPPING_STATUS_NEXT_ACTIONS.fetch(mapping_status_code.to_s, "Inspect mapping diagnostics before proceeding.")
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
