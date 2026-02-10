module CandidatesHelper
  SCOPE_OPTIONS = [
    [ "Movies", "movie" ],
    [ "TV Show", "tv_show" ],
    [ "TV Season", "tv_season" ],
    [ "TV Episode", "tv_episode" ]
  ].freeze

  SCOPE_LABELS = SCOPE_OPTIONS.to_h { |label, value| [ value, label ] }.freeze

  FLAG_LABELS = {
    "path_excluded" => "Excluded Path",
    "keep_marked" => "Keep Marked",
    "in_progress_any" => "In Progress",
    "ambiguous_mapping" => "Ambiguous Mapping",
    "ambiguous_ownership" => "Ambiguous Ownership",
    "rollup_not_strictly_eligible" => "Strict Rollup Block",
    "multiple_versions" => "Multiple Versions",
    "no_plex_mapping" => "No Plex Mapping",
    "external_id_mismatch" => "External ID Mismatch",
    "low_confidence_mapping" => "Low Confidence Mapping"
  }.freeze

  BLOCKER_HINTS = {
    "path_excluded" => "Path exclusion rule blocks deletion for this item.",
    "keep_marked" => "A keep marker blocks deletion for this item.",
    "in_progress_any" => "At least one selected Plex user is currently in progress.",
    "ambiguous_mapping" => "Mapping confidence is ambiguous and deletion is blocked.",
    "ambiguous_ownership" => "Multiple integrations claim this item path.",
    "rollup_not_strictly_eligible" => "Show or season rollup is not fully eligible."
  }.freeze

  def candidate_scope_options
    SCOPE_OPTIONS
  end

  def candidate_scope_label(scope)
    SCOPE_LABELS.fetch(scope.to_s, scope.to_s.humanize)
  end

  def candidate_flag_label(flag)
    FLAG_LABELS.fetch(flag.to_s, flag.to_s.humanize)
  end

  def candidate_blocker_hint(flag)
    BLOCKER_HINTS[flag.to_s]
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
