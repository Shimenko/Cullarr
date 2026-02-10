module Deletion
  class CreateDeletionRun
    IN_FLIGHT_ACTION_STATUSES = %w[queued running deleted unmonitored tagged].freeze
    TERMINAL_RETRYABLE_RUN_STATUSES = %w[failed canceled].freeze

    Result = Struct.new(:deletion_run, :error_code, :error_message, :error_details, keyword_init: true) do
      def success?
        error_code.nil?
      end
    end

    def initialize(operator:, unlock_token:, scope:, planned_media_file_ids:, plex_user_ids:, action_context:, correlation_id:, env: ENV)
      @operator = operator
      @unlock_token = unlock_token
      @scope = scope.to_s
      @planned_media_file_ids = planned_media_file_ids
      @plex_user_ids = plex_user_ids
      @raw_action_context = action_context
      @correlation_id = correlation_id
      @env = env
    end

    def call
      if action_context_supplied?
        return error_result(
          "validation_failed",
          "Action context must not be provided.",
          fields: { action_context: [ "is server-derived and cannot be provided" ] }
        )
      end

      unlock_result = ValidateDeleteModeUnlock.new(
        token: unlock_token,
        operator: operator,
        correlation_id: correlation_id,
        env: env
      ).call
      return unlock_result_to_create_result(unlock_result) unless unlock_result.success?

      return error_result("validation_failed", "Deletion scope is invalid.", fields: { scope: [ "must be one of: #{DeletionRun::SCOPES.join(', ')}" ] }) unless DeletionRun::SCOPES.include?(scope)

      media_file_ids = normalize_media_file_ids
      return error_result("validation_failed", "At least one media file must be planned.", fields: { planned_media_file_ids: [ "must include at least one id" ] }) if media_file_ids.empty?

      media_files = MediaFile.where(id: media_file_ids).includes(:integration, attachable: { season: :series }).index_by(&:id)
      missing_ids = media_file_ids - media_files.keys
      return error_result("validation_failed", "Planned media file IDs are invalid.", fields: { planned_media_file_ids: [ "unknown ids: #{missing_ids.join(', ')}" ] }) if missing_ids.any?
      return unsupported_integration_result(media_files) if unsupported_integration?(media_files)
      return duplicate_conflict_result(media_files) if duplicate_conflict?(media_files)

      selected_files_by_attachable = selected_files_by_attachable(media_file_ids: media_file_ids, media_files: media_files)
      context_result = BuildActionContext.new(
        scope: scope,
        selected_files_by_attachable: selected_files_by_attachable,
        series_total_file_counts_by_series_id: series_total_file_counts_by_series_id(media_files.values)
      ).call

      run = nil
      DeletionRun.transaction do
        run = DeletionRun.create!(
          operator: operator,
          status: "queued",
          scope: scope,
          selected_plex_user_ids_json: normalize_selected_plex_user_ids,
          summary_json: {
            delete_mode_unlock_id: unlock_result.unlock.id,
            planned_media_file_ids: media_file_ids,
            action_context: context_result.action_context
          }
        )

        media_file_ids.each do |media_file_id|
          media_file = media_files.fetch(media_file_id)
          DeletionAction.create!(
            deletion_run: run,
            media_file: media_file,
            integration: media_file.integration,
            idempotency_key: idempotency_key_for(run: run, media_file: media_file),
            status: "queued",
            stage_timestamps_json: {}
          )
        end
      end

      record_run_queued_event(run:, target_count: media_file_ids.size)
      Result.new(deletion_run: run)
    rescue ActiveRecord::RecordNotUnique
      error_result("conflict", "A deletion action already exists for one or more planned media files.")
    end

    private

    attr_reader :correlation_id, :env, :operator, :planned_media_file_ids, :plex_user_ids, :raw_action_context, :scope, :unlock_token

    def unlock_result_to_create_result(unlock_result)
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

    def normalize_media_file_ids
      Array(planned_media_file_ids).map { |value| Integer(value, exception: false) }.compact.select(&:positive?).uniq
    end

    def normalize_selected_plex_user_ids
      ids = Array(plex_user_ids).map { |value| Integer(value, exception: false) }.compact.select(&:positive?).uniq
      return PlexUser.order(:id).pluck(:id) if ids.empty?

      ids
    end

    def selected_files_by_attachable(media_file_ids:, media_files:)
      records_by_attachable_key = {}
      attachables = []

      media_file_ids.each do |media_file_id|
        media_file = media_files.fetch(media_file_id)
        attachable = media_file.attachable
        key = attachable_key(attachable)

        record = records_by_attachable_key[key] ||= {
          attachable: attachable,
          selected_files: [],
          all_files: []
        }
        record[:selected_files] << media_file
        attachables << attachable
      end

      ActiveRecord::Associations::Preloader.new(records: attachables.uniq, associations: :media_files).call
      records_by_attachable_key.each_value do |record|
        record[:all_files] = record.fetch(:attachable).media_files.to_a
      end

      records_by_attachable_key
    end

    def series_total_file_counts_by_series_id(media_files)
      return {} unless scope == "tv_show"

      series_ids = media_files.filter_map do |media_file|
        next unless media_file.attachable.is_a?(Episode)

        media_file.attachable.season&.series_id
      end.uniq
      return {} if series_ids.empty?

      MediaFile.joins("INNER JOIN episodes ON episodes.id = media_files.attachable_id AND media_files.attachable_type = 'Episode'")
               .joins("INNER JOIN seasons ON seasons.id = episodes.season_id")
               .where(seasons: { series_id: series_ids })
               .group("seasons.series_id")
               .count
    end

    def action_context_supplied?
      !raw_action_context.nil?
    end

    def unsupported_integration?(media_files)
      media_files.values.any? { |media_file| !media_file.integration.supported_for_delete? }
    end

    def unsupported_integration_result(media_files)
      unsupported_media_file_ids = media_files.values.select { |media_file| !media_file.integration.supported_for_delete? }.map(&:id).uniq
      error_result(
        "unsupported_integration_version",
        "One or more selected integrations are unsupported for delete operations.",
        fields: { planned_media_file_ids: [ "unsupported integration for media file ids: #{unsupported_media_file_ids.join(', ')}" ] }
      )
    end

    def duplicate_conflict?(media_files)
      @duplicate_conflict = duplicate_conflict_details(media_files)
      @duplicate_conflict[:confirmed_media_file_ids].any? || @duplicate_conflict[:in_flight_media_file_ids].any?
    end

    def duplicate_conflict_result(media_files)
      duplicate_conflict!(media_files)
      if @duplicate_conflict[:confirmed_media_file_ids].any?
        return error_result(
          "conflict",
          "One or more selected media files were already confirmed in a previous run.",
          fields: { planned_media_file_ids: [ "already confirmed media file ids: #{@duplicate_conflict[:confirmed_media_file_ids].join(', ')}" ] }
        )
      end

      error_result(
        "conflict",
        "One or more selected media files are already in progress in another run.",
        fields: { planned_media_file_ids: [ "in-flight media file ids: #{@duplicate_conflict[:in_flight_media_file_ids].join(', ')}" ] }
      )
    end

    def duplicate_conflict!(media_files)
      @duplicate_conflict ||= duplicate_conflict_details(media_files)
    end

    def duplicate_conflict_details(media_files)
      confirmed_media_file_ids = []
      in_flight_media_file_ids = []

      media_files.values.each do |media_file|
        actions = DeletionAction.joins(:media_file, :deletion_run).where(
          integration_id: media_file.integration_id,
          media_files: { arr_file_id: media_file.arr_file_id }
        )
        confirmed_media_file_ids << media_file.id if actions.where(status: "confirmed").exists?

        in_flight = actions.where(status: IN_FLIGHT_ACTION_STATUSES).where.not(deletion_runs: { status: TERMINAL_RETRYABLE_RUN_STATUSES }).exists?
        in_flight_media_file_ids << media_file.id if in_flight
      end

      {
        confirmed_media_file_ids: confirmed_media_file_ids.uniq,
        in_flight_media_file_ids: in_flight_media_file_ids.uniq
      }
    end

    def idempotency_key_for(run:, media_file:)
      "run:#{run.id}:integration:#{media_file.integration_id}:file:#{media_file.arr_file_id}"
    end

    def attachable_key(attachable)
      "#{attachable.class.name.downcase}:#{attachable.id}"
    end

    def record_run_queued_event(run:, target_count:)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.deletion.run_queued",
        correlation_id: correlation_id,
        actor: operator,
        subject: run,
        payload: {
          deletion_run_id: run.id,
          scope: run.scope,
          status: run.status,
          target_count: target_count
        }
      )
    end
  end
end
