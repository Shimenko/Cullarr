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
      {
        ambiguous_path_count: ambiguous_paths.size,
        ambiguous_media_file_count: ambiguous_paths.values.sum
      }
    end

    private

    attr_reader :correlation_id, :sync_run
  end
end
