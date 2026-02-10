module Deletion
  class ProcessAction
    class StageFailure < StandardError
      attr_reader :code, :retryable

      def initialize(code:, message:, retryable: false)
        @code = code
        @retryable = retryable
        super(message)
      end

      def to_error_code
        code.presence || "deletion_action_failed"
      end
    end

    class ConfirmPendingError < StandardError; end

    def initialize(deletion_action:, correlation_id:)
      @deletion_action = deletion_action
      @deletion_run = deletion_action.deletion_run
      @correlation_id = correlation_id
    end

    def call
      start_action_if_needed!
      return deletion_action if terminal_action?

      record_stage!("precheck")
      precheck!

      perform_delete_stage!
      perform_unmonitor_stage!
      perform_tag_stage!
      perform_confirm_stage!
      deletion_action
    rescue StageFailure => error
      fail_action!(error_code: error.to_error_code, error_message: error.message)
      record_action_failed_event(error_code: error.to_error_code, error_message: error.message, retryable: error.retryable)
      deletion_action
    rescue StandardError => error
      fail_action!(error_code: "deletion_action_failed", error_message: error.message)
      record_action_failed_event(error_code: "deletion_action_failed", error_message: error.message, retryable: false)
      deletion_action
    end

    private

    attr_reader :correlation_id, :deletion_action, :deletion_run

    def terminal_action?
      deletion_action.status.in?(%w[confirmed failed])
    end

    def start_action_if_needed!
      return unless deletion_action.status == "queued"

      deletion_action.update!(
        status: "running",
        started_at: Time.current,
        error_code: nil,
        error_message: nil
      )
      Deletion::RunStatusBroadcaster.broadcast_action(deletion_action:, correlation_id:)
    end

    def precheck!
      raise_stage_failure(code: "delete_mode_disabled", message: "Delete mode is disabled.") unless delete_mode_enabled?
      raise_stage_failure(code: "delete_mode_disabled", message: "Delete mode is not configured.") if delete_mode_secret.blank?

      unlock = DeleteModeUnlock.find_by(id: delete_mode_unlock_id)
      raise_stage_failure(code: "delete_unlock_invalid", message: "Delete unlock token is invalid.") if unlock.nil?
      raise_stage_failure(code: "delete_unlock_invalid", message: "Delete unlock token is invalid.") if unlock.operator_id != deletion_run.operator_id
      raise_stage_failure(code: "delete_unlock_expired", message: "Delete unlock token has expired.") unless unlock.active?
      raise_stage_failure(code: "unsupported_integration_version", message: "Integration is unsupported for delete operations.") unless deletion_action.integration.supported_for_delete?

      guardrails = GuardrailEvaluator.new(selected_plex_user_ids: deletion_run.selected_plex_user_ids).call(media_file: deletion_action.media_file)
      return unless guardrails.blocked?

      raise_stage_failure(
        code: guardrails.error_codes.first,
        message: "Deletion blocked by guardrail: #{guardrails.blocker_flags.first}"
      )
    end

    def perform_delete_stage!
      with_stage_retries(stage: "delete_file", attempts: 5) do
        adapter = integration_adapter
        case deletion_action.media_file.attachable
        when Movie
          adapter.delete_movie_file!(arr_file_id: deletion_action.media_file.arr_file_id)
        when Episode
          adapter.delete_episode_file!(arr_file_id: deletion_action.media_file.arr_file_id)
        else
          raise_stage_failure(code: "deletion_action_failed", message: "Unsupported attachable type for delete stage.")
        end
      end

      update_status!("deleted")
    end

    def perform_unmonitor_stage!
      return unless action_context.fetch("should_unmonitor", false)

      with_stage_retries(stage: "unmonitor", attempts: 5) do
        kind = action_context["unmonitor_kind"]
        target_id = action_context["unmonitor_target_id"]
        adapter = integration_adapter

        case kind
        when "movie"
          adapter.unmonitor_movie!(radarr_movie_id: target_id)
        when "episode"
          adapter.unmonitor_episode!(sonarr_episode_id: target_id)
        when "series"
          adapter.unmonitor_series!(sonarr_series_id: target_id)
        else
          raise_stage_failure(code: "deletion_action_failed", message: "Unsupported unmonitor target kind.")
        end
      end

      update_status!("unmonitored")
    end

    def perform_tag_stage!
      return unless action_context.fetch("should_tag", false)

      with_stage_retries(stage: "tag", attempts: 3) do
        adapter = integration_adapter
        tag_id = ensure_culled_tag_id(adapter:)

        case action_context["tag_kind"]
        when "movie"
          adapter.add_movie_tag!(radarr_movie_id: action_context["tag_target_id"], arr_tag_id: tag_id)
        when "series"
          adapter.add_series_tag!(sonarr_series_id: action_context["tag_target_id"], arr_tag_id: tag_id)
        else
          raise_stage_failure(code: "deletion_action_failed", message: "Unsupported tag target kind.")
        end
      end

      update_status!("tagged")
    rescue StageFailure => error
      append_warning_code(error.to_error_code)
      record_action_failed_event(error_code: error.to_error_code, error_message: error.message, retryable: error.retryable, non_fatal: true)
    end

    def perform_confirm_stage!
      with_stage_retries(stage: "confirm_resync", attempts: 5) do
        raise ConfirmPendingError, "Deletion confirmation is pending." if file_still_present_upstream?
      end

      deletion_action.media_file.update!(culled_at: Time.current)
      update_status!("confirmed", finished_at: Time.current)
    end

    def with_stage_retries(stage:, attempts:)
      attempt = 0

      begin
        attempt += 1
        record_stage!(stage)
        yield
      rescue StageFailure => error
        if error.retryable && attempt < attempts
          deletion_action.increment!(:retry_count)
          retry
        end

        raise_stage_failure(code: error.to_error_code, message: error.message, retryable: error.retryable)
      rescue StandardError => error
        mapped = map_stage_error(error)
        if mapped.fetch(:retryable) && attempt < attempts
          deletion_action.increment!(:retry_count)
          retry
        end

        raise_stage_failure(
          code: mapped.fetch(:code),
          message: mapped.fetch(:message),
          retryable: mapped.fetch(:retryable)
        )
      end
    end

    def raise_stage_failure(code:, message:, retryable: false)
      raise StageFailure.new(code: code, message: message, retryable: retryable)
    end

    def map_stage_error(error)
      case error
      when Integrations::RateLimitedError
        { code: "rate_limited", message: error.message, retryable: true }
      when Integrations::ConnectivityError
        { code: "integration_unreachable", message: error.message, retryable: true }
      when Integrations::AuthError
        { code: "integration_auth_failed", message: error.message, retryable: false }
      when Integrations::ContractMismatchError
        { code: "integration_contract_mismatch", message: error.message, retryable: false }
      when Integrations::UnsupportedVersionError
        { code: "unsupported_integration_version", message: error.message, retryable: false }
      when ConfirmPendingError
        { code: "deletion_confirmation_timeout", message: error.message, retryable: true }
      else
        { code: "deletion_action_failed", message: error.message, retryable: false }
      end
    end

    def update_status!(status, finished_at: nil)
      attributes = { status: status }
      attributes[:finished_at] = finished_at if finished_at.present?
      deletion_action.update!(attributes)
      record_stage_event(status:)
      Deletion::RunStatusBroadcaster.broadcast_action(deletion_action:, correlation_id:)
    end

    def fail_action!(error_code:, error_message:)
      deletion_action.update!(
        status: "failed",
        error_code: error_code,
        error_message: error_message.to_s.truncate(500),
        finished_at: Time.current
      )
      Deletion::RunStatusBroadcaster.broadcast_action(deletion_action:, correlation_id:)
    end

    def append_warning_code(code)
      json = deletion_action.stage_timestamps_json.deep_dup
      warnings = Array(json["warning_codes"]).map(&:to_s)
      warnings << code
      json["warning_codes"] = warnings.uniq
      deletion_action.update!(stage_timestamps_json: json)
    end

    def record_stage!(stage)
      json = deletion_action.stage_timestamps_json.deep_dup
      json[stage] ||= Time.current.iso8601
      deletion_action.update!(stage_timestamps_json: json)
      record_stage_event(status: deletion_action.status, stage: stage)
    end

    def record_stage_event(status:, stage: nil)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.deletion.action_stage_changed",
        correlation_id: correlation_id,
        actor: deletion_run.operator,
        subject: deletion_action,
        payload: {
          deletion_run_id: deletion_run.id,
          deletion_action_id: deletion_action.id,
          media_file_id: deletion_action.media_file_id,
          scope: deletion_run.scope,
          status: status,
          stage: stage
        }.compact
      )
    end

    def record_action_failed_event(error_code:, error_message:, retryable:, non_fatal: false)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.deletion.action_failed",
        correlation_id: correlation_id,
        actor: deletion_run.operator,
        subject: deletion_action,
        payload: {
          deletion_run_id: deletion_run.id,
          deletion_action_id: deletion_action.id,
          media_file_id: deletion_action.media_file_id,
          scope: deletion_run.scope,
          status: deletion_action.status,
          error_code: error_code,
          error_message: error_message,
          retry_count: deletion_action.retry_count,
          retryable: retryable,
          non_fatal: non_fatal
        }
      )
    end

    def integration_adapter
      @integration_adapter ||= Integrations::AdapterFactory.for(integration: deletion_action.integration)
    end

    def delete_mode_unlock_id
      deletion_run.summary_json["delete_mode_unlock_id"]
    end

    def delete_mode_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["CULLARR_DELETE_MODE_ENABLED"])
    end

    def delete_mode_secret
      ENV["CULLARR_DELETE_MODE_SECRET"].to_s
    end

    def action_context
      @action_context ||= begin
        context = deletion_run.summary_json.fetch("action_context", {})
        context.fetch(deletion_action.media_file_id.to_s, {})
      end
    end

    def ensure_culled_tag_id(adapter:)
      name = AppSetting.db_value_for("culled_tag_name").to_s
      cached_tag = ArrTag.find_by(integration_id: deletion_action.integration_id, name: name)
      return cached_tag.arr_tag_id if cached_tag.present?

      tag_id = adapter.ensure_tag!(name: name).fetch(:arr_tag_id).to_i
      ArrTag.find_or_create_by!(integration_id: deletion_action.integration_id, name: name) do |row|
        row.arr_tag_id = tag_id
      end
      tag_id
    end

    def file_still_present_upstream?
      adapter = integration_adapter
      media_file = deletion_action.media_file

      case media_file.attachable
      when Movie
        adapter.fetch_movie_files.any? { |file| file.fetch(:arr_file_id).to_i == media_file.arr_file_id }
      when Episode
        series_id = media_file.attachable.season&.series&.sonarr_series_id
        return true if series_id.blank?

        adapter.fetch_episode_files(series_id: series_id).any? do |file|
          file.fetch(:arr_file_id).to_i == media_file.arr_file_id
        end
      else
        true
      end
    end
  end
end
