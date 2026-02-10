module Sync
  class ScheduleWindow
    ACTIVE_STATUSES = %w[queued running].freeze

    def initialize(sync_enabled:, sync_interval_minutes:, now: Time.current)
      @sync_enabled = ActiveModel::Type::Boolean.new.cast(sync_enabled)
      @sync_interval_minutes = [ sync_interval_minutes.to_i, 1 ].max
      @now = now
    end

    def due?
      return false unless sync_enabled
      return false if active_or_queued_run.present?

      last_attempt_at.blank? || last_attempt_at <= sync_interval_minutes.minutes.ago
    end

    def next_scheduled_sync_at
      return nil unless sync_enabled
      return now if last_attempt_at.blank?

      [ last_attempt_at + sync_interval_minutes.minutes, now ].max
    end

    def last_successful_sync
      @last_successful_sync ||= SyncRun.where(status: "success").where.not(finished_at: nil).order(finished_at: :desc).first
    end

    def active_or_queued_run
      @active_or_queued_run ||= SyncRun.where(status: ACTIVE_STATUSES).recent_first.first
    end

    private

    attr_reader :now, :sync_enabled, :sync_interval_minutes

    def last_attempt_at
      run = recent_sync_run
      return nil if run.blank?

      run.finished_at || run.started_at || run.created_at
    end

    def recent_sync_run
      @recent_sync_run ||= SyncRun.recent_first.first
    end
  end
end
