module Sync
  class RecoverStaleRuns
    ACTIVE_JOB_CLASS_NAME = "Sync::ProcessRunJob".freeze
    RECOVERY_ERROR_CODE = "worker_lost".freeze
    RECOVERY_ERROR_MESSAGE = "Sync worker stopped before completion; run recovered as failed.".freeze
    ACTIVE_RUN_LOG_SAMPLE_SIZE = 20

    Result = Struct.new(:stale_run_ids, :requeued_run_ids, keyword_init: true)

    def initialize(correlation_id:, actor: nil, enqueue_replacement: false, stale_after: 60.seconds)
      @correlation_id = correlation_id.presence || SecureRandom.uuid
      @actor = actor
      @enqueue_replacement = ActiveModel::Type::Boolean.new.cast(enqueue_replacement)
      @stale_after = [ stale_after.to_i, 1 ].max.seconds
    end

    def call
      stale_runs = []
      replacement_runs = []

      SyncRun.with_active_queue_lock do
        stale_runs = stale_runs_without_active_jobs
        stale_runs.each { |sync_run| recover!(sync_run) }
        replacement_runs = enqueue_replacements_for(stale_runs) if enqueue_replacement?
      end

      replacement_runs.each do |sync_run|
        Sync::ProcessRunJob.perform_later(sync_run.id, correlation_id)
      end

      broadcast_progress_if_needed(stale_runs:, replacement_runs:)

      Result.new(
        stale_run_ids: stale_runs.map(&:id),
        requeued_run_ids: replacement_runs.map(&:id)
      )
    end

    private

    attr_reader :actor, :correlation_id, :stale_after

    def enqueue_replacement?
      @enqueue_replacement
    end

    def stale_runs_without_active_jobs
      stale_scope = SyncRun
        .where(status: "running")
        .where("updated_at <= ?", stale_after.ago)
      stale_candidate_ids = stale_scope.order(:id).pluck(:id)
      active_run_ids = active_running_run_ids_from_queue
      log_recovery_scan(stale_candidate_ids:, active_run_ids:)
      stale_scope = stale_scope.where.not(id: active_run_ids) if active_run_ids.any?
      stale_scope.lock.order(:id).to_a
    end

    def active_running_run_ids_from_queue
      return [] unless queue_tables_available?

      run_ids = active_running_queue_arguments
        .filter_map { |raw_arguments| extract_run_id(raw_arguments) }
        .uniq
      log_active_run_ids(run_ids)
      run_ids
    rescue ActiveRecord::StatementInvalid, NameError
      []
    end

    def queue_tables_available?
      [ SolidQueue::Job, SolidQueue::ClaimedExecution, SolidQueue::Process ].all? do |table_class|
        table_class.connection.data_source_exists?(table_class.table_name)
      end
    rescue ActiveRecord::ActiveRecordError, NameError
      false
    end

    def process_alive_cutoff
      process_alive_threshold = SolidQueue.respond_to?(:process_alive_threshold) ? SolidQueue.process_alive_threshold : 5.minutes
      [ process_alive_threshold.to_i, 1 ].max.seconds.ago
    end

    def active_running_queue_arguments
      SolidQueue::Job
        .joins(claimed_execution: :process)
        .where(class_name: ACTIVE_JOB_CLASS_NAME, finished_at: nil)
        .where("#{SolidQueue::Process.table_name}.last_heartbeat_at > ?", process_alive_cutoff)
        .pluck(:arguments)
    end

    def extract_run_id(raw_arguments)
      payload = raw_arguments.is_a?(String) ? JSON.parse(raw_arguments) : raw_arguments
      run_id = payload&.dig("arguments", 0)
      parsed = Integer(run_id, exception: false)
      parsed if parsed&.positive?
    rescue JSON::ParserError, TypeError
      nil
    end

    def recover!(sync_run)
      sync_run.update!(
        status: "failed",
        error_code: RECOVERY_ERROR_CODE,
        error_message: RECOVERY_ERROR_MESSAGE,
        finished_at: Time.current
      )
      record_recovered_event(sync_run)
      log_recovered(sync_run)
    end

    def enqueue_replacements_for(stale_runs)
      return [] if stale_runs.empty?
      return [] if SyncRun.where(status: "queued").exists?

      sync_run = SyncRun.create!(status: "queued", trigger: "system_bootstrap")
      record_queued_event(sync_run, stale_runs.last)
      log_requeued(sync_run, stale_runs.last)
      [ sync_run ]
    end

    def broadcast_progress_if_needed(stale_runs:, replacement_runs:)
      return if stale_runs.empty? && replacement_runs.empty?

      reference_run = replacement_runs.first || SyncRun.recent_first.first
      Sync::RunProgressBroadcaster.broadcast(sync_run: reference_run, correlation_id: correlation_id)
    end

    def record_recovered_event(sync_run)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.sync.run_recovered_stale",
        correlation_id: correlation_id,
        actor: actor,
        subject: sync_run,
        payload: {
          sync_run_id: sync_run.id,
          previous_status: "running",
          recovered_status: "failed",
          recovery_error_code: RECOVERY_ERROR_CODE
        }
      )
    end

    def record_queued_event(queued_run, recovered_run)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.sync.run_queued",
        correlation_id: correlation_id,
        actor: actor,
        subject: queued_run,
        payload: {
          sync_run_id: queued_run.id,
          trigger: queued_run.trigger,
          recovered_from_sync_run_id: recovered_run.id
        }
      )
    end

    def log_recovered(sync_run)
      Rails.logger.warn(
        [
          "sync_run_recovered_stale",
          "sync_run_id=#{sync_run.id}",
          "status=#{sync_run.status}",
          "error_code=#{sync_run.error_code}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_requeued(sync_run, recovered_run)
      Rails.logger.info(
        [
          "sync_run_requeued_after_recovery",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "recovered_from_sync_run_id=#{recovered_run.id}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_recovery_scan(stale_candidate_ids:, active_run_ids:)
      return if stale_candidate_ids.empty? && active_run_ids.empty?

      Rails.logger.info(
        [
          "sync_run_recovery_scan",
          "stale_candidates=#{stale_candidate_ids.size}",
          "stale_candidate_ids=#{sample_ids(stale_candidate_ids)}",
          "active_from_queue=#{active_run_ids.size}",
          "active_run_ids=#{sample_ids(active_run_ids)}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_active_run_ids(run_ids)
      return if run_ids.empty?

      Rails.logger.info(
        [
          "sync_run_recovery_active_queue_runs",
          "count=#{run_ids.size}",
          "run_ids=#{sample_ids(run_ids)}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def sample_ids(ids)
      ids.first(ACTIVE_RUN_LOG_SAMPLE_SIZE).join(",")
    end
  end
end
