module Sync
  module TautulliLibraryMapping
    class Telemetry
      FLAT_PHASE_COUNT_KEYS = %i[
        mapping_total_duration_ms
        discovery_duration_ms
        discovery_library_page_calls
        discovery_tv_child_page_calls
        discovery_tv_show_expansions
        discovery_tv_season_expansions
        discovery_tv_rows_emitted
        metadata_recheck_duration_ms
        recheck_watchable_metadata_cache_hits
        recheck_watchable_metadata_cache_misses
        recheck_show_metadata_cache_hits
        recheck_show_metadata_cache_misses
        recheck_budget_exhausted_rows
        tv_structure_duration_ms
        tv_structure_series_rating_key_queries
        tv_structure_series_external_id_queries
        tv_structure_season_queries
        tv_structure_episode_queries
        tv_structure_series_rating_key_cache_hits
        tv_structure_series_external_id_cache_hits
        tv_structure_season_cache_hits
        tv_structure_episode_cache_hits
        persistence_duration_ms
      ].freeze

      def self.phase_counts_template
        FLAT_PHASE_COUNT_KEYS.index_with(0)
      end

      def initialize
        @counters = self.class.phase_counts_template
      end

      def measure_discovery(&block)
        measure(:discovery_duration_ms, &block)
      end

      def measure_metadata_recheck(&block)
        measure(:metadata_recheck_duration_ms, &block)
      end

      def measure_tv_structure(&block)
        measure(:tv_structure_duration_ms, &block)
      end

      def measure_persistence(&block)
        measure(:persistence_duration_ms, &block)
      end

      def increment_discovery_library_page_calls(by: 1)
        increment(:discovery_library_page_calls, by:)
      end

      def increment_discovery_tv_child_page_calls(by: 1)
        increment(:discovery_tv_child_page_calls, by:)
      end

      def increment_discovery_tv_show_expansions(by: 1)
        increment(:discovery_tv_show_expansions, by:)
      end

      def increment_discovery_tv_season_expansions(by: 1)
        increment(:discovery_tv_season_expansions, by:)
      end

      def increment_discovery_tv_rows_emitted(by: 1)
        increment(:discovery_tv_rows_emitted, by:)
      end

      def increment_watchable_metadata_cache_hit
        increment(:recheck_watchable_metadata_cache_hits)
      end

      def increment_watchable_metadata_cache_miss
        increment(:recheck_watchable_metadata_cache_misses)
      end

      def increment_show_metadata_cache_hit
        increment(:recheck_show_metadata_cache_hits)
      end

      def increment_show_metadata_cache_miss
        increment(:recheck_show_metadata_cache_misses)
      end

      def increment_recheck_budget_exhausted_rows
        increment(:recheck_budget_exhausted_rows)
      end

      def increment_tv_structure_query(kind)
        increment(tv_structure_query_key_for(kind))
      end

      def increment_tv_structure_cache_hit(kind)
        increment(tv_structure_cache_hit_key_for(kind))
      end

      def phase_counts_payload(mapping_total_duration_ms:)
        @counters.merge(mapping_total_duration_ms: mapping_total_duration_ms.to_i)
      end

      def last_run_telemetry_payload(profile:, rows_fetched:, rows_processed:, duration_ms:)
        {
          "profile" => profile.to_s,
          "rows_fetched" => rows_fetched.to_i,
          "rows_processed" => rows_processed.to_i,
          "duration_ms" => duration_ms.to_i,
          "discovery" => {
            "duration_ms" => counter(:discovery_duration_ms),
            "library_page_calls" => counter(:discovery_library_page_calls),
            "tv_child_page_calls" => counter(:discovery_tv_child_page_calls),
            "tv_show_expansions" => counter(:discovery_tv_show_expansions),
            "tv_season_expansions" => counter(:discovery_tv_season_expansions),
            "tv_rows_emitted" => counter(:discovery_tv_rows_emitted)
          },
          "metadata_recheck" => {
            "duration_ms" => counter(:metadata_recheck_duration_ms),
            "watchable_cache_hits" => counter(:recheck_watchable_metadata_cache_hits),
            "watchable_cache_misses" => counter(:recheck_watchable_metadata_cache_misses),
            "show_cache_hits" => counter(:recheck_show_metadata_cache_hits),
            "show_cache_misses" => counter(:recheck_show_metadata_cache_misses),
            "budget_exhausted_rows" => counter(:recheck_budget_exhausted_rows)
          },
          "tv_structure" => {
            "duration_ms" => counter(:tv_structure_duration_ms),
            "series_rating_key_queries" => counter(:tv_structure_series_rating_key_queries),
            "series_external_id_queries" => counter(:tv_structure_series_external_id_queries),
            "season_queries" => counter(:tv_structure_season_queries),
            "episode_queries" => counter(:tv_structure_episode_queries),
            "series_rating_key_cache_hits" => counter(:tv_structure_series_rating_key_cache_hits),
            "series_external_id_cache_hits" => counter(:tv_structure_series_external_id_cache_hits),
            "season_cache_hits" => counter(:tv_structure_season_cache_hits),
            "episode_cache_hits" => counter(:tv_structure_episode_cache_hits)
          },
          "persistence" => {
            "duration_ms" => counter(:persistence_duration_ms)
          }
        }
      end

      private

      def counter(key)
        @counters.fetch(key, 0).to_i
      end

      def increment(key, by: 1)
        @counters[key] = counter(key) + by.to_i
      end

      def measure(key)
        started_at = monotonic_now
        yield
      ensure
        increment(key, by: elapsed_ms_since(started_at))
      end

      def elapsed_ms_since(started_at)
        ((monotonic_now - started_at) * 1000).round
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def tv_structure_query_key_for(kind)
        case kind
        when :series_rating_key
          :tv_structure_series_rating_key_queries
        when :series_external_id
          :tv_structure_series_external_id_queries
        when :season
          :tv_structure_season_queries
        when :episode
          :tv_structure_episode_queries
        else
          raise ArgumentError, "unsupported tv structure query kind: #{kind.inspect}"
        end
      end

      def tv_structure_cache_hit_key_for(kind)
        case kind
        when :series_rating_key
          :tv_structure_series_rating_key_cache_hits
        when :series_external_id
          :tv_structure_series_external_id_cache_hits
        when :season
          :tv_structure_season_cache_hits
        when :episode
          :tv_structure_episode_cache_hits
        else
          raise ArgumentError, "unsupported tv structure cache kind: #{kind.inspect}"
        end
      end
    end
  end
end
