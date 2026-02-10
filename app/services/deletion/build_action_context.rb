module Deletion
  class BuildActionContext
    Result = Struct.new(:action_context, :warnings, keyword_init: true)

    def initialize(scope:, selected_files_by_attachable:, series_total_file_counts_by_series_id: nil)
      @scope = scope.to_s
      @selected_files_by_attachable = selected_files_by_attachable
      @series_total_file_counts_by_series_id = normalize_series_counts(series_total_file_counts_by_series_id)
    end

    def call
      warnings = []
      action_context = {}
      show_context = show_context_for if scope == "tv_show"

      selected_files_by_attachable.each_value do |value|
        attachable = value.fetch(:attachable)
        selected_files = value.fetch(:selected_files)
        all_files = value.fetch(:all_files)

        selected_files.each do |media_file|
          context = context_for_media_file(
            attachable: attachable,
            media_file: media_file,
            selected_files: selected_files,
            all_files: all_files,
            show_context: show_context
          )

          warnings << "partial_version_delete_no_parent_unmonitor" if partial_selection_warning?(context: context, selected_files: selected_files, all_files: all_files)
          action_context[media_file.id.to_s] = context
        end
      end

      Result.new(action_context: action_context, warnings: warnings.uniq)
    end

    private

    attr_reader :scope, :selected_files_by_attachable, :series_total_file_counts_by_series_id

    def show_context_for
      series_to_files = Hash.new { |hash, key| hash[key] = [] }
      inferred_series_total_counts = Hash.new(0)

      selected_files_by_attachable.each_value do |value|
        episode = value.fetch(:attachable)
        series = episode.season&.series
        next if series.nil?

        series_to_files[series.id].concat(value.fetch(:selected_files))
        inferred_series_total_counts[series.id] += value.fetch(:all_files).size
      end

      full_show_delete_by_series_id = {}
      first_selected_file_by_series_id = {}

      series_to_files.each do |series_id, files|
        selected_count = files.map(&:id).uniq.size
        total_count = series_total_file_counts_by_series_id.fetch(series_id, inferred_series_total_counts.fetch(series_id, 0))
        full_show_delete_by_series_id[series_id] = selected_count.positive? && total_count.positive? && selected_count == total_count
        first_selected_file_by_series_id[series_id] = files.map(&:id).min
      end

      {
        full_show_delete_by_series_id: full_show_delete_by_series_id,
        first_selected_file_by_series_id: first_selected_file_by_series_id
      }
    end

    def context_for_media_file(attachable:, media_file:, selected_files:, all_files:, show_context:)
      full_attachable_selection = selected_files.size == all_files.size

      case scope
      when "movie"
        {
          should_unmonitor: full_attachable_selection || partial_parent_unmonitor?,
          unmonitor_kind: "movie",
          unmonitor_target_id: attachable.radarr_movie_id,
          should_tag: full_attachable_selection && media_file.id == selected_files.map(&:id).min,
          tag_kind: "movie",
          tag_target_id: attachable.radarr_movie_id
        }
      when "tv_episode", "tv_season"
        {
          should_unmonitor: full_attachable_selection || partial_parent_unmonitor?,
          unmonitor_kind: "episode",
          unmonitor_target_id: attachable.sonarr_episode_id,
          should_tag: false
        }
      when "tv_show"
        context_for_show_media_file(attachable:, media_file:, show_context:)
      else
        {
          should_unmonitor: false,
          should_tag: false
        }
      end
    end

    def context_for_show_media_file(attachable:, media_file:, show_context:)
      series_id = attachable.season&.series_id
      full_show_delete = show_context.fetch(:full_show_delete_by_series_id).fetch(series_id, false)

      {
        should_unmonitor: full_show_delete || partial_parent_unmonitor?,
        unmonitor_kind: "series",
        unmonitor_target_id: attachable.season&.series&.sonarr_series_id,
        should_tag: full_show_delete && media_file.id == show_context.fetch(:first_selected_file_by_series_id).fetch(series_id, nil),
        tag_kind: "series",
        tag_target_id: attachable.season&.series&.sonarr_series_id
      }
    end

    def partial_selection_warning?(context:, selected_files:, all_files:)
      selected_files.size < all_files.size && !context.fetch(:should_unmonitor)
    end

    def partial_parent_unmonitor?
      ActiveModel::Type::Boolean.new.cast(
        AppSetting.db_value_for("unmonitor_parent_on_partial_version_delete")
      )
    end

    def normalize_series_counts(counts)
      return {} if counts.blank?

      counts.to_h.each_with_object({}) do |(series_id, total_count), normalized|
        normalized_series_id = Integer(series_id, exception: false)
        normalized_total_count = Integer(total_count, exception: false)
        next if normalized_series_id.nil? || normalized_total_count.nil?

        normalized[normalized_series_id] = normalized_total_count
      end
    end
  end
end
