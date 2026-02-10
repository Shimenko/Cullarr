class RunsController < ApplicationController
  def index
    @running_sync_run = SyncRun.where(status: "running").recent_first.first
    @recent_sync_runs = SyncRun.recent_first.limit(20)
    @running_deletion_run = DeletionRun.where(status: "running").recent_first.first
    @recent_deletion_runs = DeletionRun.includes(:deletion_actions).recent_first.limit(20)
    @deletion_summary_by_run_id = DeletionRun.action_summary_by_run_id(@recent_deletion_runs.map(&:id))
    @sync_enabled = ActiveModel::Type::Boolean.new.cast(AppSetting.db_value_for("sync_enabled"))
    @sync_interval_minutes = [ AppSetting.db_value_for("sync_interval_minutes").to_i, 1 ].max
    @last_successful_sync = SyncRun.where(status: "success").where.not(finished_at: nil).order(finished_at: :desc).first
    @next_scheduled_sync_at = next_scheduled_sync_at
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

  def next_scheduled_sync_at
    return nil unless @sync_enabled
    return Time.current if @last_successful_sync.blank?

    @last_successful_sync.finished_at + @sync_interval_minutes.minutes
  end
end
