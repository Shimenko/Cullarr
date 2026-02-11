class Sync::SchedulerJob < ApplicationJob
  queue_as :default

  def perform
    correlation_id = SecureRandom.uuid
    recovery_result = recover_stale_runs!(correlation_id:)
    return if recovery_result.requeued_run_ids.any?

    schedule_window = build_schedule_window
    return unless schedule_window.due?

    Sync::TriggerRun.new(
      trigger: "scheduler",
      correlation_id: correlation_id,
      actor: nil
    ).call
  rescue StandardError => error
    Rails.logger.warn("sync_scheduler_failed class=#{error.class} message=#{error.message}")
    raise
  end

  private

  def recover_stale_runs!(correlation_id:)
    Sync::RecoverStaleRuns.new(
      correlation_id: correlation_id,
      actor: nil,
      enqueue_replacement: true
    ).call
  end

  def build_schedule_window
    Sync::ScheduleWindow.new(
      sync_enabled: AppSetting.db_value_for("sync_enabled"),
      sync_interval_minutes: AppSetting.db_value_for("sync_interval_minutes")
    )
  end
end
