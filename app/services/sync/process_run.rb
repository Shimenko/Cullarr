module Sync
  class ProcessRun
    def initialize(sync_run:, correlation_id: nil)
      @sync_run = sync_run
      @correlation_id = correlation_id.presence || SecureRandom.uuid
    end

    def call
      unless transition_to_running!
        record_run_skipped_event
        log_run_skipped!
        RunProgressBroadcaster.broadcast(sync_run: sync_run, correlation_id: correlation_id)
        return sync_run
      end

      run_started_at = Time.current
      log_run_started!
      record_run_started_event
      phase_counts = RunSync.new(sync_run:, correlation_id: correlation_id).call
      transition_to_success!(phase_counts:)
      log_run_succeeded!(run_started_at:, phase_counts:)
      record_run_succeeded_event
      enqueue_coalesced_run_if_needed
      sync_run
    rescue StandardError => error
      transition_to_failed!(error)
      log_run_failed!(error)
      record_run_failed_event(error)
      enqueue_coalesced_run_if_needed
      sync_run
    end

    private

    attr_reader :correlation_id, :sync_run

    def transition_to_running!
      SyncRun.transaction do
        sync_run.lock!
        return false unless sync_run.status == "queued"

        sync_run.update!(
          status: "running",
          started_at: Time.current,
          phase: "starting",
          phase_counts_json: {},
          error_code: nil,
          error_message: nil
        )
      end

      RunProgressBroadcaster.broadcast(sync_run: sync_run, correlation_id: correlation_id)
      true
    end

    def transition_to_success!(phase_counts:)
      sync_run.update!(
        status: "success",
        phase: "complete",
        phase_counts_json: sync_run.phase_counts_json.merge(phase_counts),
        finished_at: Time.current
      )
      RunProgressBroadcaster.broadcast(sync_run: sync_run, correlation_id: correlation_id)
    end

    def transition_to_failed!(error)
      sync_run.update!(
        status: "failed",
        error_code: error_code_for(error),
        error_message: error.message.to_s.truncate(500),
        finished_at: Time.current
      )
      RunProgressBroadcaster.broadcast(sync_run: sync_run, correlation_id: correlation_id)
    end

    def enqueue_coalesced_run_if_needed
      next_run = nil

      SyncRun.with_active_queue_lock do
        sync_run.reload
        break unless sync_run.queued_next?

        existing_queued_run = SyncRun.where(status: "queued").where.not(id: sync_run.id).recent_first.first
        if existing_queued_run.present?
          sync_run.update!(queued_next: false)
          next_run = existing_queued_run
          break
        end

        queued_trigger = queued_next_trigger_for(sync_run)
        sync_run.update!(queued_next: false)
        next_run = SyncRun.create!(status: "queued", trigger: queued_trigger)
        record_run_queued_event(next_run, queued_from_sync_run_id: sync_run.id)
      end

      Sync::ProcessRunJob.perform_later(next_run.id, correlation_id) if next_run.present?
      log_coalesced_run_enqueued!(next_run) if next_run.present?
    end

    def queued_next_trigger_for(sync_run_record)
      payload = AuditEvent
        .where(event_name: "cullarr.sync.run_queued_next", subject_type: "SyncRun", subject_id: sync_run_record.id)
        .order(occurred_at: :desc, id: :desc)
        .limit(1)
        .pick(:payload_json)
      payload&.dig("trigger").presence || sync_run_record.trigger
    end

    def record_run_started_event
      record_event("cullarr.sync.run_started", { sync_run_id: sync_run.id, trigger: sync_run.trigger })
    end

    def record_run_succeeded_event
      record_event(
        "cullarr.sync.run_succeeded",
        {
          sync_run_id: sync_run.id,
          trigger: sync_run.trigger,
          phase_counts: sync_run.public_phase_counts
        }
      )
    end

    def record_run_failed_event(error)
      record_event(
        "cullarr.sync.run_failed",
        {
          sync_run_id: sync_run.id,
          trigger: sync_run.trigger,
          error_code: error_code_for(error),
          error_message: error.message.to_s
        }
      )
    end

    def record_run_skipped_event
      record_event(
        "cullarr.sync.run_skipped",
        {
          sync_run_id: sync_run.id,
          trigger: sync_run.trigger,
          status: sync_run.status,
          reason: "not_queued"
        }
      )
    end

    def record_run_queued_event(sync_run_record, queued_from_sync_run_id:)
      record_event(
        "cullarr.sync.run_queued",
        {
          sync_run_id: sync_run_record.id,
          trigger: sync_run_record.trigger,
          queued_from_sync_run_id: queued_from_sync_run_id
        },
        subject: sync_run_record
      )
    end

    def record_event(event_name, payload, subject: sync_run)
      AuditEvents::Recorder.record!(
        event_name: event_name,
        correlation_id: correlation_id,
        actor: nil,
        subject: subject,
        payload: payload
      )
    end

    def error_code_for(error)
      case error
      when Integrations::UnsupportedVersionError
        "unsupported_integration_version"
      when Integrations::RateLimitedError
        "rate_limited"
      when Integrations::AuthError
        "integration_auth_failed"
      when Integrations::ContractMismatchError
        "integration_contract_mismatch"
      when Integrations::ConnectivityError
        "integration_unreachable"
      else
        "sync_phase_failed"
      end
    end

    def log_run_started!
      Rails.logger.info(
        [
          "sync_run_started",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "status=#{sync_run.status}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_run_skipped!
      Rails.logger.warn(
        [
          "sync_run_skipped",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "status=#{sync_run.status}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_run_succeeded!(run_started_at:, phase_counts:)
      duration_ms = ((Time.current - run_started_at) * 1000).round
      Rails.logger.info(
        [
          "sync_run_succeeded",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "duration_ms=#{duration_ms}",
          "phase_counts=#{phase_counts.to_json}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_run_failed!(error)
      Rails.logger.error(
        [
          "sync_run_failed",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "error_class=#{error.class}",
          "error_code=#{error_code_for(error)}",
          "error_message=#{error.message}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_coalesced_run_enqueued!(next_run)
      Rails.logger.info(
        [
          "sync_run_coalesced_enqueue",
          "from_sync_run_id=#{sync_run.id}",
          "next_sync_run_id=#{next_run.id}",
          "trigger=#{next_run.trigger}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end
  end
end
