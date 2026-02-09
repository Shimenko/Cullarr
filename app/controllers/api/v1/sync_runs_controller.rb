module Api
  module V1
    class SyncRunsController < BaseController
      before_action :set_sync_run, only: :show

      def create
        trigger = params[:trigger].presence || "manual"
        return render_invalid_trigger_error unless trigger == "manual"

        result = Sync::TriggerRun.new(
          trigger: trigger,
          correlation_id: request.request_id,
          actor: current_operator
        ).call

        case result.state
        when :queued
          render json: { sync_run: result.sync_run.as_api_json }, status: :accepted
        when :queued_next
          render json: { code: "sync_queued_next", sync_run: result.sync_run.as_api_json }, status: :accepted
        else
          render_api_error(
            code: "sync_already_running",
            message: "A sync run is already running or queued.",
            status: :conflict
          )
        end
      end

      def index
        sync_runs = paginated_sync_runs
        return if performed?

        render json: { sync_runs: sync_runs[:records].map(&:as_api_json), page: { next_cursor: sync_runs[:next_cursor] } }
      end

      def show
        render json: { sync_run: @sync_run.as_api_json }
      end

      private

      def set_sync_run
        @sync_run = SyncRun.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Sync run not found.", status: :not_found)
      end

      def limit_param
        requested = params[:limit].presence
        return 25 if requested.blank?

        Integer(requested, exception: false).to_i.clamp(1, 100)
      end

      def cursor_param
        raw_cursor = params[:cursor].presence
        return nil if raw_cursor.blank?

        cursor = Integer(raw_cursor, exception: false)
        return cursor if cursor.present? && cursor.positive?

        render_validation_error(fields: { cursor: [ "must be a positive integer" ] })
        nil
      end

      def paginated_sync_runs
        limit = limit_param
        cursor = cursor_param
        return { records: [], next_cursor: nil } if performed?

        scope = SyncRun.recent_first
        scope = scope.where("id < ?", cursor) if cursor.present?

        rows = scope.limit(limit + 1).to_a
        has_more = rows.size > limit
        records = has_more ? rows.first(limit) : rows
        next_cursor = has_more ? records.last&.id : nil

        { records: records, next_cursor: next_cursor }
      end

      def render_invalid_trigger_error
        render_validation_error(fields: { trigger: [ "must be manual" ] })
      end
    end
  end
end
