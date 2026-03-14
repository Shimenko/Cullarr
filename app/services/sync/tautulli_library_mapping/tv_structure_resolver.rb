module Sync
  module TautulliLibraryMapping
    class TvStructureResolver
      def initialize
        @series_by_rating_key_cache = {}
        @series_by_external_id_cache = {}
        @season_lookup_cache = {}
        @episode_lookup_cache = {}
      end

      def resolve_tv_structure_candidates(context:, integration:)
        return empty_tv_structure_result unless context.fetch(:media_type) == "episode"

        season_episode_keys = {
          season_number: context[:season_number],
          episode_number: context[:episode_number],
          parent_rating_key: context[:plex_parent_rating_key],
          grandparent_rating_key: context[:plex_grandparent_rating_key]
        }
        fallback_path = context[:tv_episode_metadata_fallback] ? "episode_metadata" : nil
        if season_episode_keys[:season_number].blank? || season_episode_keys[:episode_number].blank?
          return {
            outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_MISSING_KEYS,
            show_identity_source: {
              source: nil,
              value: nil,
              status: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_MISSING_KEYS
            },
            season_episode_keys: season_episode_keys,
            fallback_path: fallback_path,
            candidate_count: 0,
            unique_watchable: nil,
            conflict_reason: nil
          }
        end

        show_identity = resolve_show_identity_for_tv_structure(context:, integration:)
        if show_identity.fetch(:conflict_reason).present?
          return {
            outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_AMBIGUOUS,
            show_identity_source: show_identity.fetch(:show_identity_source),
            season_episode_keys: season_episode_keys,
            fallback_path: fallback_path,
            candidate_count: 0,
            unique_watchable: nil,
            conflict_reason: show_identity.fetch(:conflict_reason)
          }
        end

        series = show_identity.fetch(:series)
        if series.blank?
          return {
            outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_UNRESOLVED_SHOW,
            show_identity_source: show_identity.fetch(:show_identity_source),
            season_episode_keys: season_episode_keys,
            fallback_path: fallback_path,
            candidate_count: 0,
            unique_watchable: nil,
            conflict_reason: nil
          }
        end

        episode_candidates = tv_episode_candidates_for(
          series: series,
          season_number: season_episode_keys.fetch(:season_number),
          episode_number: season_episode_keys.fetch(:episode_number)
        )

        if episode_candidates.size > 1
          return {
            outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_AMBIGUOUS,
            show_identity_source: show_identity.fetch(:show_identity_source),
            season_episode_keys: season_episode_keys,
            fallback_path: fallback_path,
            candidate_count: episode_candidates.size,
            unique_watchable: nil,
            conflict_reason: Sync::TautulliLibraryMappingSync::CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS
          }
        end

        unique_episode = episode_candidates.first
        if unique_episode.present?
          return {
            outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_RESOLVED,
            show_identity_source: show_identity.fetch(:show_identity_source),
            season_episode_keys: season_episode_keys,
            fallback_path: fallback_path,
            candidate_count: 1,
            unique_watchable: unique_episode,
            conflict_reason: nil
          }
        end

        {
          outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_UNRESOLVED_EPISODE,
          show_identity_source: show_identity.fetch(:show_identity_source),
          season_episode_keys: season_episode_keys,
          fallback_path: fallback_path,
          candidate_count: 0,
          unique_watchable: nil,
          conflict_reason: nil
        }
      end

      private

      def resolve_show_identity_for_tv_structure(context:, integration:)
        show_rating_key = context[:plex_grandparent_rating_key].to_s.strip.presence
        show_external_ids = context.fetch(:show_external_ids, {})
        rating_key_candidates = series_candidates_for_show_rating_key(
          show_rating_key: show_rating_key,
          integration_id: integration.id
        )
        external_id_candidates = series_candidates_for_show_external_ids(show_external_ids:)

        rating_key_unique = rating_key_candidates.one? ? rating_key_candidates.first : nil
        external_unique = external_id_candidates.one? ? external_id_candidates.first : nil

        if rating_key_unique.present? && external_unique.present? &&
            !same_watchable?(rating_key_unique, external_unique)
          return {
            series: nil,
            conflict_reason: Sync::TautulliLibraryMappingSync::CONFLICT_REASON_STRONG_SIGNAL_DISAGREEMENT,
            show_identity_source: {
              source: "mixed_show_signals",
              value: {
                grandparent_rating_key: show_rating_key,
                show_external_ids: show_external_ids
              },
              status: "strong_signal_disagreement"
            }
          }
        end

        if rating_key_candidates.size > 1 || external_id_candidates.size > 1
          return {
            series: nil,
            conflict_reason: Sync::TautulliLibraryMappingSync::CONFLICT_REASON_MULTIPLE_EXTERNAL_IDS,
            show_identity_source: {
              source: "mixed_show_signals",
              value: {
                grandparent_rating_key: show_rating_key,
                show_external_ids: show_external_ids
              },
              status: "multiple_candidates"
            }
          }
        end

        if rating_key_unique.present?
          return {
            series: rating_key_unique,
            conflict_reason: nil,
            show_identity_source: {
              source: "plex_grandparent_rating_key",
              value: show_rating_key,
              status: "resolved_unique"
            }
          }
        end

        if external_unique.present?
          return {
            series: external_unique,
            conflict_reason: nil,
            show_identity_source: {
              source: "show_metadata_external_ids",
              value: show_external_ids,
              status: "resolved_unique"
            }
          }
        end

        {
          series: nil,
          conflict_reason: nil,
          show_identity_source: {
            source: nil,
            value: show_rating_key.presence || show_external_ids.presence,
            status: "unresolved"
          }
        }
      end

      def series_candidates_for_show_rating_key(show_rating_key:, integration_id:)
        normalized_key = show_rating_key.to_s.strip.presence
        return [] if normalized_key.blank?

        cache_key = [ integration_id, normalized_key ]
        @series_by_rating_key_cache.fetch(cache_key) do
          @series_by_rating_key_cache[cache_key] = Series.where(plex_rating_key: normalized_key).to_a
        end
      end

      def series_candidates_for_show_external_ids(show_external_ids:)
        normalized_ids = normalized_external_ids(show_external_ids)
        return [] if normalized_ids.blank?

        cache_key = [
          normalized_ids[:tvdb_id],
          normalized_ids[:imdb_id],
          normalized_ids[:tmdb_id]
        ]
        @series_by_external_id_cache.fetch(cache_key) do
          candidates = Series.none
          candidates = candidates.or(Series.where(tvdb_id: normalized_ids[:tvdb_id])) if normalized_ids[:tvdb_id].present?
          candidates = candidates.or(Series.where(imdb_id: normalized_ids[:imdb_id])) if normalized_ids[:imdb_id].present?
          candidates = candidates.or(Series.where(tmdb_id: normalized_ids[:tmdb_id])) if normalized_ids[:tmdb_id].present?
          @series_by_external_id_cache[cache_key] = candidates.to_a.uniq(&:id)
        end
      end

      def tv_episode_candidates_for(series:, season_number:, episode_number:)
        season = season_for_series(series_id: series.id, season_number: season_number)
        return [] if season.blank?

        episode_cache_key = [ season.id, episode_number.to_i ]
        @episode_lookup_cache.fetch(episode_cache_key) do
          @episode_lookup_cache[episode_cache_key] = Episode.where(
            season_id: season.id,
            episode_number: episode_number.to_i
          ).to_a
        end
      end

      def season_for_series(series_id:, season_number:)
        cache_key = [ series_id, season_number.to_i ]
        @season_lookup_cache.fetch(cache_key) do
          @season_lookup_cache[cache_key] = Season.where(
            series_id: series_id,
            season_number: season_number.to_i
          ).first
        end
      end

      def empty_tv_structure_result
        {
          outcome: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_NON_TV,
          show_identity_source: {
            source: nil,
            value: nil,
            status: Sync::TautulliLibraryMappingSync::TV_STRUCTURE_OUTCOME_NON_TV
          },
          season_episode_keys: {
            season_number: nil,
            episode_number: nil,
            parent_rating_key: nil,
            grandparent_rating_key: nil
          },
          fallback_path: nil,
          candidate_count: 0,
          unique_watchable: nil,
          conflict_reason: nil
        }
      end

      def normalized_external_ids(external_ids)
        hash = external_ids.is_a?(Hash) ? external_ids : {}
        imdb_id = hash[:imdb_id].to_s.strip.presence || hash["imdb_id"].to_s.strip.presence
        tmdb_id = integer_or_nil(hash[:tmdb_id] || hash["tmdb_id"])
        tvdb_id = integer_or_nil(hash[:tvdb_id] || hash["tvdb_id"])
        {
          imdb_id: imdb_id,
          tmdb_id: tmdb_id,
          tvdb_id: tvdb_id
        }.compact
      end

      def integer_or_nil(value)
        parsed = Integer(value, exception: false)
        return nil unless parsed&.positive?

        parsed
      end

      def same_watchable?(left, right)
        return false if left.blank? || right.blank?

        left.class.name == right.class.name && left.id == right.id
      end
    end
  end
end
