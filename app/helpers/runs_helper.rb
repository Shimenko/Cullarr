module RunsHelper
  def sync_run_status_badge_kind(sync_run)
    case sync_run.status
    when "success"
      :success
    when "failed", "canceled"
      :danger
    when "running"
      :info
    when "queued"
      :warning
    else
      :neutral
    end
  end

  def sync_run_progress_variant(sync_run)
    case sync_run.status
    when "success"
      :success
    when "failed", "canceled"
      :danger
    else
      :accent
    end
  end

  def sync_run_phase_label(phase_name)
    Sync::RunSync.phase_label_for(phase_name.presence || "starting")
  end

  def sync_run_progress_caption(sync_run)
    progress = sync_run.progress_snapshot
    current_phase_percent = progress[:current_phase_percent].to_f.round(1)
    "#{progress[:completed_phases]}/#{progress[:total_phases]} phases complete · current phase #{current_phase_percent}%"
  end

  def sync_run_duration_label(sync_run)
    duration = sync_run.duration_seconds
    return "-" if duration.blank?

    "#{duration.round(1)}s"
  end

  def sync_run_timestamp(value)
    value&.strftime("%Y-%m-%d %H:%M:%S") || "-"
  end

  def sync_phase_progress_text(phase_state)
    total_units = phase_state[:total_units].to_i
    processed_units = phase_state[:processed_units].to_i
    percent_complete = phase_state[:percent_complete].to_f.round(1)

    return phase_state[:state] if total_units <= 0

    "#{processed_units}/#{total_units} (#{percent_complete}%)"
  end
end
