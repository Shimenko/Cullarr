class RunsController < ApplicationController
  def index
    @running_sync_run = SyncRun.where(status: "running").recent_first.first
    @recent_sync_runs = SyncRun.recent_first.limit(20)
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
end
