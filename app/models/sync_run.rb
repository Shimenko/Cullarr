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
      phase_counts: phase_counts_json,
      started_at: started_at,
      finished_at: finished_at,
      queued_next: queued_next,
      created_at: created_at,
      updated_at: updated_at
    }
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
end
