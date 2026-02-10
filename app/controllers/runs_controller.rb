class RunsController < ApplicationController
  def index
    schedule_window = sync_schedule_window

    @running_sync_run = SyncRun.where(status: "running").recent_first.first
    @recent_sync_runs = SyncRun.recent_first.limit(20)
    @running_deletion_run = DeletionRun.where(status: "running").recent_first.first
    @recent_deletion_runs = DeletionRun.includes(:deletion_actions).recent_first.limit(20)
    @deletion_summary_by_run_id = DeletionRun.action_summary_by_run_id(@recent_deletion_runs.map(&:id))
    @sync_enabled = ActiveModel::Type::Boolean.new.cast(AppSetting.db_value_for("sync_enabled"))
    @sync_interval_minutes = [ AppSetting.db_value_for("sync_interval_minutes").to_i, 1 ].max
    @last_successful_sync = schedule_window.last_successful_sync
    @next_scheduled_sync_at = schedule_window.next_scheduled_sync_at
  end

  def sync_now
    result = Sync::TriggerRun.new(
      trigger: "manual",
      correlation_id: request.request_id,
      actor: current_operator
    ).call

    case result.state
    when :queued
      redirect_to runs_path, notice: "Sync queued."
    when :queued_next
      redirect_to runs_path, notice: "Sync queued to run next."
    else
      redirect_to runs_path, alert: "A sync run is already active or queued."
    end
  rescue StandardError
    redirect_to runs_path, alert: "Unable to queue sync right now."
  end

  private

  def sync_schedule_window
    Sync::ScheduleWindow.new(
      sync_enabled: AppSetting.db_value_for("sync_enabled"),
      sync_interval_minutes: AppSetting.db_value_for("sync_interval_minutes")
    )
  end
end
