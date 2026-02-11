class CandidatesController < ApplicationController
  DEFAULT_SCOPE = "movie".freeze

  def index
    @plex_users = PlexUser.order(:friendly_name, :id)
    load_candidates!(
      scope: normalized_scope(params[:scope]),
      plex_user_ids: params[:plex_user_ids],
      include_blocked: params[:include_blocked],
      watched_match_mode: params[:watched_match_mode].presence || "none"
    )
  rescue Candidates::Query::InvalidScopeError, Candidates::Query::InvalidFilterError, Candidates::Query::SavedViewNotFoundError => error
    flash.now[:alert] = candidates_error_message(error)
    load_candidates!(
      scope: DEFAULT_SCOPE,
      plex_user_ids: nil,
      include_blocked: false,
      watched_match_mode: "none"
    )
  end

  private

  def load_candidates!(scope:, plex_user_ids:, include_blocked:, watched_match_mode:)
    result = Candidates::Query.new(
      scope: scope,
      saved_view_id: nil,
      plex_user_ids: plex_user_ids,
      include_blocked: include_blocked,
      watched_match_mode: watched_match_mode,
      cursor: nil,
      limit: nil,
      correlation_id: request.request_id,
      actor: current_operator
    ).call

    @scope = result.scope
    @selected_plex_user_ids = Array(result.filters[:plex_user_ids]).map(&:to_i)
    @include_blocked = ActiveModel::Type::Boolean.new.cast(result.filters[:include_blocked])
    @watched_match_mode = result.filters[:watched_match_mode].presence || "none"
    @items = result.items.map(&:with_indifferent_access)
    @candidate_diagnostics = result.diagnostics.to_h.with_indifferent_access
    @next_cursor = result.next_cursor
    result
  end

  def normalized_scope(raw_scope)
    scope = raw_scope.to_s
    return DEFAULT_SCOPE if scope.blank?
    return scope if Candidates::Query::SUPPORTED_SCOPES.include?(scope)

    DEFAULT_SCOPE
  end

  def candidates_error_message(error)
    case error
    when Candidates::Query::InvalidFilterError
      first_message = error.fields.values.flatten.first
      "Candidate filters are invalid. #{first_message}".strip
    when Candidates::Query::SavedViewNotFoundError
      "Saved view was not found."
    else
      "Candidate scope is invalid."
    end
  end
end
