module Deletion
  class PlanDeletionRun
    Result = Struct.new(:plan, :error_code, :error_message, :error_details, keyword_init: true) do
      def success?
        error_code.nil?
      end
    end

    def initialize(operator:, unlock_token:, scope:, selection:, version_selection:, plex_user_ids:, correlation_id:, env: ENV)
      @operator = operator
      @unlock_token = unlock_token
      @scope = scope.to_s
      @selection = normalize_hash(selection)
      @version_selection = normalize_hash(version_selection)
      @plex_user_ids = plex_user_ids
      @correlation_id = correlation_id
      @env = env
    end

    def call
      unlock_result = ValidateDeleteModeUnlock.new(
        token: unlock_token,
        operator: operator,
        correlation_id: correlation_id,
        env: env
      ).call
      return unlock_result_to_plan_result(unlock_result) unless unlock_result.success?

      return error_result("validation_failed", "Deletion scope is invalid.", fields: { scope: [ "must be one of: #{DeletionRun::SCOPES.join(', ')}" ] }) unless DeletionRun::SCOPES.include?(scope)

      selected_plex_user_ids = resolve_selected_plex_user_ids
      attachables = selected_attachables
      return error_result("validation_failed", "No targets selected for planning.", fields: { selection: [ "must include at least one target" ] }) if attachables.empty?

      selection_result = select_media_files_for_attachables(attachables)
      return selection_result if selection_result.is_a?(Result) && !selection_result.success?

      selected_files_by_attachable = selection_result
      unsupported_ids = unsupported_media_file_ids(selected_files_by_attachable)
      if unsupported_ids.any?
        return error_result(
          "unsupported_integration_version",
          "One or more selected integrations are unsupported for delete operations.",
          fields: { planned_media_file_ids: [ "unsupported integration for media file ids: #{unsupported_ids.join(', ')}" ] }
        )
      end

      context_result = BuildActionContext.new(scope: scope, selected_files_by_attachable: selected_files_by_attachable).call
      evaluator = GuardrailEvaluator.new(selected_plex_user_ids:)

      blockers = []
      warnings = []
      action_context = context_result.action_context
      eligible_media_file_ids = []
      total_reclaimable_bytes = 0

      selected_files_by_attachable.each_value do |value|
        selected_files = value.fetch(:selected_files)
        all_files = value.fetch(:all_files)

        selected_files.each do |media_file|
          guardrail_result = evaluator.call(media_file:)
          if guardrail_result.blocked?
            blockers << {
              media_file_id: media_file.id,
              blocker_flags: guardrail_result.blocker_flags,
              error_codes: guardrail_result.error_codes
            }
            next
          end

          context = action_context.fetch(media_file.id.to_s)
          warnings << "partial_version_delete_no_parent_unmonitor" if selected_files.size < all_files.size && !context[:should_unmonitor]
          eligible_media_file_ids << media_file.id
          total_reclaimable_bytes += media_file.size_bytes
        end
      end

      plan = {
        target_count: eligible_media_file_ids.size,
        total_reclaimable_bytes: total_reclaimable_bytes,
        warnings: warnings.uniq,
        blockers: blockers,
        planned_media_file_ids: eligible_media_file_ids,
        selected_plex_user_ids: selected_plex_user_ids,
        action_context: action_context
      }
      record_plan_event(plan:)

      Result.new(plan:)
    end

    private

    attr_reader :correlation_id, :env, :operator, :plex_user_ids, :scope, :selection, :unlock_token, :version_selection

    def unlock_result_to_plan_result(unlock_result)
      Result.new(
        error_code: unlock_result.error_code,
        error_message: unlock_result.error_message
      )
    end

    def error_result(error_code, error_message, fields: {})
      Result.new(
        error_code: error_code,
        error_message: error_message,
        error_details: fields.present? ? { fields: fields } : {}
      )
    end

    def normalize_hash(value)
      return value.to_unsafe_h.deep_stringify_keys if value.respond_to?(:to_unsafe_h)
      return value.to_h.deep_stringify_keys if value.respond_to?(:to_h)

      {}
    end

    def unsupported_media_file_ids(selected_files_by_attachable)
      selected_files_by_attachable.each_value.flat_map do |value|
        value.fetch(:selected_files).select { |media_file| !media_file.integration.supported_for_delete? }.map(&:id)
      end.uniq
    end

    def selected_attachables
      case scope
      when "movie"
        ids = positive_integer_array(selection["movie_ids"])
        Movie.where(id: ids).includes(:watch_stats, :keep_markers, :media_files)
      when "tv_episode"
        ids = positive_integer_array(selection["episode_ids"])
        Episode.where(id: ids).includes(:watch_stats, :keep_markers, :media_files, season: %i[keep_markers series])
      when "tv_season"
        ids = positive_integer_array(selection["season_ids"])
        Season.where(id: ids).includes(episodes: [ :watch_stats, :keep_markers, :media_files, { season: { series: :keep_markers } } ])
      when "tv_show"
        ids = positive_integer_array(selection["series_ids"] || selection["show_ids"])
        Series.where(id: ids).includes(seasons: { episodes: %i[watch_stats keep_markers media_files] }, keep_markers: [], integration: [])
      else
        []
      end
    end

    def select_media_files_for_attachables(attachables)
      selected = {}

      case scope
      when "movie", "tv_episode"
        attachables.each do |attachable|
          result = selected_files_for_attachable(attachable)
          return result if result.is_a?(Result)

          selected[attachable_key(attachable)] = {
            attachable: attachable,
            selected_files: result[:selected_files],
            all_files: result[:all_files]
          }
        end
      when "tv_season"
        attachables.each do |season|
          season.episodes.each do |episode|
            result = selected_files_for_attachable(episode)
            return result if result.is_a?(Result)

            selected[attachable_key(episode)] = {
              attachable: episode,
              selected_files: result[:selected_files],
              all_files: result[:all_files]
            }
          end
        end
      when "tv_show"
        attachables.each do |series|
          series.seasons.each do |season|
            season.episodes.each do |episode|
              result = selected_files_for_attachable(episode)
              return result if result.is_a?(Result)

              selected[attachable_key(episode)] = {
                attachable: episode,
                selected_files: result[:selected_files],
                all_files: result[:all_files],
                series: series
              }
            end
          end
        end
      end

      selected
    end

    def selected_files_for_attachable(attachable)
      all_files = attachable.media_files.to_a
      return { selected_files: [], all_files: [] } if all_files.empty?

      if all_files.size == 1
        return { selected_files: all_files, all_files: all_files }
      end

      selection_key = version_selection_key(attachable)
      raw_selected_ids = positive_integer_array(version_selection[selection_key])
      if raw_selected_ids.empty?
        return error_result(
          "multi_version_selection_required",
          "Explicit version selection is required.",
          fields: { version_selection: [ "missing selection for #{selection_key}" ] }
        )
      end

      allowed_ids = all_files.map(&:id)
      selected_ids = raw_selected_ids & allowed_ids
      if selected_ids.empty?
        return error_result(
          "validation_failed",
          "Selected versions are invalid.",
          fields: { version_selection: [ "selection for #{selection_key} does not reference available media files" ] }
        )
      end

      { selected_files: all_files.select { |file| selected_ids.include?(file.id) }, all_files: all_files }
    end

    def resolve_selected_plex_user_ids
      requested_ids = positive_integer_array(plex_user_ids)
      return PlexUser.order(:id).pluck(:id) if requested_ids.empty?

      requested_ids
    end

    def positive_integer_array(values)
      Array(values).map { |value| Integer(value, exception: false) }.compact.select(&:positive?).uniq
    end

    def attachable_key(attachable)
      "#{attachable.class.name.downcase}:#{attachable.id}"
    end

    def version_selection_key(attachable)
      case attachable
      when Movie
        "movie:#{attachable.id}"
      when Episode
        "episode:#{attachable.id}"
      else
        "#{attachable.class.name.downcase}:#{attachable.id}"
      end
    end

    def record_plan_event(plan:)
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.deletion.run_planned",
        correlation_id: correlation_id,
        actor: operator,
        subject_type: "DeletionRun",
        payload: {
          scope: scope,
          target_count: plan[:target_count],
          blocker_count: plan[:blockers].size,
          warning_count: plan[:warnings].size
        }
      )
    end
  end
end
