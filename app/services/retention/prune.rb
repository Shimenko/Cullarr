module Retention
  class Prune
    TERMINAL_SYNC_RUN_STATUSES = %w[success failed canceled].freeze
    TERMINAL_DELETION_RUN_STATUSES = %w[success partial_failure failed canceled].freeze

    Result = Struct.new(
      :sync_runs_deleted,
      :deletion_runs_deleted,
      :deletion_actions_deleted,
      :audit_events_deleted,
      :correlation_id,
      keyword_init: true
    )

    def initialize(correlation_id: "retention-prune-#{SecureRandom.uuid}", logger: Rails.logger, now: Time.current)
      @correlation_id = correlation_id
      @logger = logger
      @now = now
    end

    def call
      sync_runs_deleted = prune_sync_runs!
      deletion_result = prune_deletion_runs_and_actions!
      audit_events_deleted = prune_audit_events!

      result = Result.new(
        sync_runs_deleted: sync_runs_deleted,
        deletion_runs_deleted: deletion_result.fetch(:deletion_runs_deleted),
        deletion_actions_deleted: deletion_result.fetch(:deletion_actions_deleted),
        audit_events_deleted: audit_events_deleted,
        correlation_id: correlation_id
      )
      log_result(result)
      result
    end

    private

    attr_reader :correlation_id, :logger, :now

    def prune_sync_runs!
      cutoff = retention_cutoff_for("retention_sync_runs_days")
      return 0 if cutoff.blank?

      SyncRun
        .where(status: TERMINAL_SYNC_RUN_STATUSES)
        .where.not(finished_at: nil)
        .where("finished_at < ?", cutoff)
        .delete_all
    end

    def prune_deletion_runs_and_actions!
      cutoff = retention_cutoff_for("retention_deletion_runs_days")
      return { deletion_runs_deleted: 0, deletion_actions_deleted: 0 } if cutoff.blank?

      deletion_run_ids = DeletionRun
        .where(status: TERMINAL_DELETION_RUN_STATUSES)
        .where.not(finished_at: nil)
        .where("finished_at < ?", cutoff)
        .pluck(:id)

      return { deletion_runs_deleted: 0, deletion_actions_deleted: 0 } if deletion_run_ids.empty?

      deletion_actions_deleted = DeletionAction.where(deletion_run_id: deletion_run_ids).delete_all
      deletion_runs_deleted = DeletionRun.where(id: deletion_run_ids).delete_all
      {
        deletion_runs_deleted: deletion_runs_deleted,
        deletion_actions_deleted: deletion_actions_deleted
      }
    end

    def prune_audit_events!
      retention_days = AppSetting.db_value_for("retention_audit_events_days").to_i
      return 0 if retention_days <= 0

      cutoff = now - retention_days.days
      AuditEvent.where("occurred_at < ?", cutoff).delete_all
    end

    def retention_cutoff_for(key)
      retention_days = AppSetting.db_value_for(key).to_i
      return nil if retention_days <= 0

      now - retention_days.days
    end

    def log_result(result)
      logger.info(
        [
          "retention_prune_completed",
          "correlation_id=#{result.correlation_id}",
          "sync_runs_deleted=#{result.sync_runs_deleted}",
          "deletion_runs_deleted=#{result.deletion_runs_deleted}",
          "deletion_actions_deleted=#{result.deletion_actions_deleted}",
          "audit_events_deleted=#{result.audit_events_deleted}"
        ].join(" ")
      )
    end
  end
end
