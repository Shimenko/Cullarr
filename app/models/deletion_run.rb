class DeletionRun < ApplicationRecord
  SUMMARY_STATUSES = %w[queued running confirmed failed deleted unmonitored tagged].freeze
  STATUSES = %w[queued running success partial_failure failed canceled].freeze
  SCOPES = %w[movie tv_show tv_season tv_episode].freeze

  belongs_to :operator

  has_many :deletion_actions, dependent: :destroy

  scope :recent_first, -> { order(id: :desc) }

  validates :scope, inclusion: { in: SCOPES }
  validates :status, inclusion: { in: STATUSES }

  class << self
    def action_summary_by_run_id(run_ids)
      normalized_run_ids = Array(run_ids)
        .map { |run_id| Integer(run_id, exception: false) }
        .compact
        .uniq
      return {} if normalized_run_ids.empty?

      grouped_counts = DeletionAction
        .where(deletion_run_id: normalized_run_ids, status: SUMMARY_STATUSES)
        .group(:deletion_run_id, :status)
        .count

      normalized_run_ids.each_with_object({}) do |run_id, summaries|
        summaries[run_id] = default_action_summary.merge(
          SUMMARY_STATUSES.index_with { |status| grouped_counts.fetch([ run_id, status ], 0) }
                         .transform_keys(&:to_sym)
        )
      end
    end

    def default_action_summary
      SUMMARY_STATUSES.index_with(0).transform_keys(&:to_sym)
    end
  end

  def selected_plex_user_ids
    Array(selected_plex_user_ids_json).map { |id| Integer(id, exception: false) }.compact.select(&:positive?).uniq
  end

  def as_api_json
    {
      id: id,
      status: status,
      scope: scope,
      summary: action_summary,
      error_code: error_code,
      error_message: error_message,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at,
      updated_at: updated_at,
      actions: deletion_actions.order(:id).map(&:as_api_json)
    }
  end

  private

  def action_summary
    self.class.action_summary_by_run_id([ id ]).fetch(id, self.class.default_action_summary)
  end
end
