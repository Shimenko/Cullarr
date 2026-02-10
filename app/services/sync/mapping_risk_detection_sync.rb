module Sync
  class MappingRiskDetectionSync
    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      ambiguous_paths = MediaFile.group(:path_canonical)
                                 .having("COUNT(DISTINCT integration_id) > 1")
                                 .count
      counts = {
        ambiguous_path_count: ambiguous_paths.size,
        ambiguous_media_file_count: ambiguous_paths.values.sum
      }
      log_info("sync_phase_worker_completed phase=mapping_risk_detection counts=#{counts.to_json}")
      counts
    end

    private

    attr_reader :correlation_id, :sync_run

    def log_info(message)
      Rails.logger.info(
        [
          message,
          "sync_run_id=#{sync_run.id}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end
  end
end
