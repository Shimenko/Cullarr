module Sync
  class MappingHealthMetrics
    def call
      ambiguous_paths = MediaFile.group(:path_canonical)
                                 .having("COUNT(DISTINCT integration_id) > 1")
                                 .count

      {
        enabled_path_mappings: PathMapping.where(enabled: true).count,
        media_files_total: MediaFile.count,
        media_files_with_canonical_path: MediaFile.where.not(path_canonical: [ nil, "" ]).count,
        ambiguous_path_count: ambiguous_paths.size,
        ambiguous_media_file_count: ambiguous_paths.values.sum,
        integrations_without_path_mappings: Integration.where(kind: %w[sonarr radarr])
                                                       .left_outer_joins(:path_mappings)
                                                       .where(path_mappings: { id: nil })
                                                       .count
      }
    end
  end
end
