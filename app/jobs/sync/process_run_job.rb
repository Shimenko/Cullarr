class Sync::ProcessRunJob < ApplicationJob
  queue_as :default

  def perform(sync_run_id, correlation_id = nil)
    sync_run = SyncRun.find_by(id: sync_run_id)
    return if sync_run.blank?

    Sync::ProcessRun.new(sync_run:, correlation_id: correlation_id).call
  end
end
