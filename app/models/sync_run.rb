class SyncRun < ApplicationRecord
  ACTIVE_QUEUE_LOCK_KEY = "sync_active_queue_lock".freeze

  STATUSES = %w[queued running success failed canceled].freeze
  TRIGGERS = %w[manual scheduler system_bootstrap].freeze
  RUNNING_PHASE_PROGRESS_UNITS = 0.5

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
      phase_counts: phase_counts_json,
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
    completed_phase_keys = phase_counts_json.keys & phase_order
    total_phases = phase_order.size
    current_phase_key = phase.to_s.presence
    current_phase_index = phase_order.index(current_phase_key)
    completed_phases = completed_phase_keys.size

    progress_units = progress_units_for(
      total_phases: total_phases,
      completed_phases: completed_phases,
      current_phase_index: current_phase_index
    )

    {
      total_phases: total_phases,
      completed_phases: completed_phases,
      current_phase: current_phase_key,
      current_phase_label: Sync::RunSync.phase_label_for(current_phase_key.presence || "starting"),
      current_phase_index: current_phase_index&.+(1),
      percent_complete: percent_for(units: progress_units, total: total_phases),
      phase_states: phase_order.map { |phase_name| phase_state_for(phase_name, completed_phase_keys) }
    }
  end

  def duration_seconds
    from = started_at || created_at
    to = finished_at || Time.current
    return nil if from.blank?

    (to - from).round(1)
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

  def progress_units_for(total_phases:, completed_phases:, current_phase_index:)
    return total_phases if status == "success"
    return 0 if status == "queued"
    return completed_phases if status.in?(%w[failed canceled])
    return completed_phases if current_phase_index.blank?

    [ completed_phases + RUNNING_PHASE_PROGRESS_UNITS, total_phases - 0.01 ].min
  end

  def percent_for(units:, total:)
    return 0.0 if total <= 0

    ((units.to_f / total) * 100).clamp(0, 100).round(1)
  end

  def phase_state_for(phase_name, completed_phase_keys)
    state = if completed_phase_keys.include?(phase_name)
      "complete"
    elsif status == "failed" && phase == phase_name
      "failed"
    elsif status == "canceled" && phase == phase_name
      "canceled"
    elsif status == "running" && phase == phase_name
      "current"
    else
      "pending"
    end

    {
      phase: phase_name,
      label: Sync::RunSync.phase_label_for(phase_name),
      state: state
    }
  end
end
