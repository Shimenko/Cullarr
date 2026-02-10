module Deletion
  class ProcessRun
    def initialize(deletion_run:, correlation_id:)
      @deletion_run = deletion_run
      @correlation_id = correlation_id
    end

    def call
      return deletion_run unless transition_to_running!

      record_run_event("cullarr.deletion.run_started", status: "running")
      process_actions!
      finalize_run_status!
      deletion_run
    rescue StandardError => error
      deletion_run.update!(
        status: "failed",
        error_code: "deletion_action_failed",
        error_message: error.message.to_s.truncate(500),
        finished_at: Time.current
      )
      record_run_event("cullarr.deletion.run_failed", status: deletion_run.status, error_code: deletion_run.error_code, error_message: deletion_run.error_message)
      Deletion::RunStatusBroadcaster.broadcast_run(deletion_run:, correlation_id:)
      deletion_run
    end

    private

    attr_reader :correlation_id, :deletion_run

    def transition_to_running!
      DeletionRun.transaction do
        deletion_run.lock!
        return false unless deletion_run.status == "queued"

        deletion_run.update!(
          status: "running",
          started_at: Time.current,
          finished_at: nil,
          error_code: nil,
          error_message: nil
        )
      end

      Deletion::RunStatusBroadcaster.broadcast_run(deletion_run:, correlation_id:)
      true
    end

    def process_actions!
      deletion_run.deletion_actions.order(:id).find_each do |action|
        deletion_run.reload
        break if deletion_run.status == "canceled"

        ProcessAction.new(deletion_action: action, correlation_id: correlation_id).call
      end
    end

    def finalize_run_status!
      deletion_run.reload
      if deletion_run.status == "canceled"
        record_run_event("cullarr.deletion.run_canceled", status: deletion_run.status)
        Deletion::RunStatusBroadcaster.broadcast_run(deletion_run:, correlation_id:)
        return
      end

      statuses = deletion_run.deletion_actions.pluck(:status)
      final_status = if statuses.all? { |status| status == "confirmed" }
        "success"
      elsif statuses.any? { |status| status == "failed" } && statuses.any? { |status| status == "confirmed" }
        "partial_failure"
      elsif statuses.any? { |status| status == "failed" }
        "failed"
      else
        "failed"
      end

      deletion_run.update!(status: final_status, finished_at: Time.current)

      event_name = case final_status
      when "success"
        "cullarr.deletion.run_succeeded"
      when "partial_failure"
        "cullarr.deletion.run_partial_failure"
      else
        "cullarr.deletion.run_failed"
      end
      record_run_event(event_name, status: final_status)
      Deletion::RunStatusBroadcaster.broadcast_run(deletion_run:, correlation_id:)
    end

    def record_run_event(event_name, status:, error_code: nil, error_message: nil)
      AuditEvents::Recorder.record!(
        event_name: event_name,
        correlation_id: correlation_id,
        actor: deletion_run.operator,
        subject: deletion_run,
        payload: {
          deletion_run_id: deletion_run.id,
          status: status,
          scope: deletion_run.scope,
          error_code: error_code,
          error_message: error_message
        }.compact
      )
    end
  end
end
