class SyncRun < ApplicationRecord
  ACTIVE_QUEUE_LOCK_KEY = "sync_active_queue_lock".freeze

  STATUSES = %w[queued running success failed canceled].freeze
  TRIGGERS = %w[manual scheduler system_bootstrap].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
  validate :single_active_status, if: :active_status?

  scope :recent_first, -> { order(id: :desc) }

  class << self
    def with_active_queue_lock
      AppSetting.transaction do
        active_queue_lock_row!.touch
        yield
      end
    end

    private

    def active_queue_lock_row!
      AppSetting.find_or_create_by!(key: ACTIVE_QUEUE_LOCK_KEY) do |setting|
        setting.value_json = {}
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end

  def as_api_json
    {
      id: id,
      status: status,
      trigger: trigger,
      phase: phase,
      phase_counts: public_phase_counts,
      progress: progress_snapshot,
      started_at: started_at,
      finished_at: finished_at,
      duration_seconds: duration_seconds,
      queued_next: queued_next,
      error_code: error_code,
      error_message: error_message,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  def progress_snapshot
    phase_order = Sync::RunSync.phase_order
    progress_data = Sync::ProgressTracker.progress_data_for(self)
    phase_progresses = phase_progresses_for(phase_order:, progress_data:)
    completed_phases = phase_progresses.count { |phase_progress| phase_progress[:state] == "complete" }
    total_phases = phase_order.size
    current_phase_key = phase_progresses.find { |phase_progress| phase_progress[:state] == "current" }&.fetch(:phase, nil) || phase.to_s.presence
    current_phase_index = phase_order.index(current_phase_key)
    current_phase_percent = current_phase_key.present? ? phase_percent_for(phase_progresses:, phase_name: current_phase_key) : 0.0
    overall_percent = overall_percent_for(phase_progresses:, total_phases:)

    {
      total_phases: total_phases,
      completed_phases: completed_phases,
      current_phase: current_phase_key,
      current_phase_label: Sync::RunSync.phase_label_for(current_phase_key.presence || "starting"),
      current_phase_index: current_phase_index&.+(1),
      current_phase_percent: current_phase_percent,
      percent_complete: overall_percent,
      phase_states: phase_progresses
    }
  end

  def duration_seconds
    from = started_at || created_at
    to = finished_at || Time.current
    return nil if from.blank?

    (to - from).round(1)
  end

  def public_phase_counts
    phase_counts_json.except(Sync::ProgressTracker::PROGRESS_KEY)
  end

  private

  def active_status?
    status.in?(%w[queued running])
  end

  def single_active_status
    scope = self.class.where(status: status)
    scope = scope.where.not(id: id) if persisted?
    return unless scope.exists?

    errors.add(:status, "already has an active #{status} run")
  end

  def phase_progresses_for(phase_order:, progress_data:)
    phase_data = progress_data.fetch("phases", {})
    completed_phase_keys = completed_phase_keys_for(phase_order:)
    current_phase = phase.to_s

    phase_order.map do |phase_name|
      phase_entry = (phase_data[phase_name] || {}).deep_symbolize_keys
      total_units = [ phase_entry.fetch(:total_units, 0).to_i, 0 ].max
      processed_units = [ phase_entry.fetch(:processed_units, 0).to_i, 0 ].max
      processed_units = total_units if total_units.positive? && processed_units > total_units
      state = phase_state_for(phase_name:, phase_entry:, completed_phase_keys:, current_phase:)
      percent_complete = if state == "complete"
        100.0
      else
        phase_percent(total_units:, processed_units:)
      end
      if state == "current" && percent_complete >= 100.0
        percent_complete = 99.9
      end

      {
        phase: phase_name,
        label: Sync::RunSync.phase_label_for(phase_name),
        state: state,
        total_units: total_units,
        processed_units: processed_units,
        percent_complete: percent_complete
      }
    end
  end

  def phase_state_for(phase_name:, phase_entry:, completed_phase_keys:, current_phase:)
    explicit_state = phase_entry[:state].to_s.presence
    return "complete" if status == "success" && completed_phase_keys.include?(phase_name)
    return explicit_state if explicit_state.present? && explicit_state != "pending"
    return "complete" if completed_phase_keys.include?(phase_name)
    return "failed" if status == "failed" && current_phase == phase_name
    return "canceled" if status == "canceled" && current_phase == phase_name
    return "current" if status == "running" && current_phase == phase_name

    "pending"
  end

  def phase_percent(total_units:, processed_units:)
    return 0.0 if total_units <= 0

    ((processed_units.to_f / total_units.to_f) * 100.0).clamp(0, 100).round(1)
  end

  def phase_percent_for(phase_progresses:, phase_name:)
    phase_progresses.find { |phase_progress| phase_progress[:phase] == phase_name }&.fetch(:percent_complete, 0.0).to_f
  end

  def overall_percent_for(phase_progresses:, total_phases:)
    return 0.0 if total_phases <= 0
    return 100.0 if status == "success"

    ratios = phase_progresses.map do |phase_progress|
      phase_progress.fetch(:percent_complete).to_f / 100.0
    end
    ((ratios.sum / total_phases) * 100.0).clamp(0, 100).round(1)
  end

  def completed_phase_keys_for(phase_order:)
    public_phase_counts.keys & phase_order
  end
end
