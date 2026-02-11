module Api
  module V1
    class CandidatesController < BaseController
      def index
        query = Candidates::Query.new(
          scope: params[:scope],
          saved_view_id: params[:saved_view_id],
          plex_user_ids: params[:plex_user_ids],
          include_blocked: params[:include_blocked],
          watched_match_mode: params[:watched_match_mode],
          cursor: params[:cursor],
          limit: params[:limit],
          correlation_id: request.request_id,
          actor: current_operator
        )
        result = query.call

        render json: {
          scope: result.scope,
          filters: result.filters,
          diagnostics: result.diagnostics,
          items: result.items,
          page: {
            next_cursor: result.next_cursor
          }
        }
      rescue Candidates::Query::InvalidScopeError => e
        render_validation_error(fields: { scope: [ e.message ] })
      rescue Candidates::Query::InvalidFilterError => e
        render_validation_error(fields: e.fields)
      rescue Candidates::Query::SavedViewNotFoundError => e
        render_api_error(code: "not_found", message: "Saved view not found.", status: :not_found, details: { saved_view_id: e.saved_view_id })
      end

      private
    end
  end
end
