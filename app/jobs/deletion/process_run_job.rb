class Deletion::ProcessRunJob < ApplicationJob
  queue_as :default

  def perform(deletion_run_id, correlation_id = nil)
    deletion_run = DeletionRun.find_by(id: deletion_run_id)
    return if deletion_run.blank?

    Deletion::ProcessRun.new(
      deletion_run: deletion_run,
      correlation_id: correlation_id.presence || SecureRandom.uuid
    ).call
  end
end
