class Sync::SchedulerJob < ApplicationJob
  queue_as :default

  def perform
    return unless AppSetting.db_value_for("sync_enabled")
    return unless sync_due?

    Sync::TriggerRun.new(
      trigger: "scheduler",
      correlation_id: SecureRandom.uuid,
      actor: nil
    ).call
  end

  private

  def sync_due?
    interval_minutes = AppSetting.db_value_for("sync_interval_minutes").to_i
    interval_minutes = 30 if interval_minutes <= 0

    last_successful_sync = SyncRun.where(status: "success").order(finished_at: :desc).first
    return true if last_successful_sync.blank?

    last_successful_sync.finished_at.blank? || last_successful_sync.finished_at <= interval_minutes.minutes.ago
  end
end
