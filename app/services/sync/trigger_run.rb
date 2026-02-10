module Sync
  class TriggerRun
    Result = Struct.new(:state, :sync_run, keyword_init: true)

    def initialize(trigger:, correlation_id:, actor: nil)
      @trigger = trigger
      @correlation_id = correlation_id.presence || SecureRandom.uuid
      @actor = actor
    end

    def call
      sync_run_to_enqueue = nil
      result = nil

      SyncRun.with_active_queue_lock do
        running_run = SyncRun.where(status: "running").recent_first.first
        queued_run = SyncRun.where(status: "queued").recent_first.first

        if running_run.present?
          result = handle_running_run(running_run, queued_run)
        elsif queued_run.present?
          result = Result.new(state: :conflict, sync_run: queued_run)
        else
          sync_run = SyncRun.create!(status: "queued", trigger: trigger)
          record_run_queued_event(sync_run)
          sync_run_to_enqueue = sync_run
          result = Result.new(state: :queued, sync_run: sync_run)
        end
      end

      enqueue!(sync_run_to_enqueue) if sync_run_to_enqueue.present?
      if result&.state.in?([ :queued, :queued_next ])
        RunProgressBroadcaster.broadcast(sync_run: result.sync_run, correlation_id: correlation_id)
      end
      log_result!(result)
      result
    end

    private

    attr_reader :actor, :correlation_id, :trigger

    def handle_running_run(running_run, queued_run)
      return Result.new(state: :conflict, sync_run: running_run) if running_run.queued_next? || queued_run.present?

      running_run.update!(queued_next: true)
      record_run_queued_next_event(running_run)
      Result.new(state: :queued_next, sync_run: running_run)
    end

    def enqueue!(sync_run)
      Sync::ProcessRunJob.perform_later(sync_run.id, correlation_id)
    end

    def record_run_queued_event(sync_run)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.sync.run_queued",
        correlation_id: correlation_id,
        actor: actor,
        subject: sync_run,
        payload: {
          sync_run_id: sync_run.id,
          trigger: sync_run.trigger
        }
      )
    end

    def record_run_queued_next_event(sync_run)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.sync.run_queued_next",
        correlation_id: correlation_id,
        actor: actor,
        subject: sync_run,
        payload: {
          active_sync_run_id: sync_run.id,
          queued_next: true,
          trigger: trigger
        }
      )
    end

    def log_result!(result)
      return if result.blank?

      Rails.logger.info(
        [
          "sync_run_triggered",
          "state=#{result.state}",
          "sync_run_id=#{result.sync_run&.id}",
          "trigger=#{trigger}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end
  end
end
