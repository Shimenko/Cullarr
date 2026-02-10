class DeletionRun < ApplicationRecord
  STATUSES = %w[queued running success partial_failure failed canceled].freeze
  SCOPES = %w[movie tv_show tv_season tv_episode].freeze

  belongs_to :operator

  has_many :deletion_actions, dependent: :destroy

  scope :recent_first, -> { order(id: :desc) }

  validates :scope, inclusion: { in: SCOPES }
  validates :status, inclusion: { in: STATUSES }

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
    grouped = deletion_actions.group(:status).count
    {
      queued: grouped.fetch("queued", 0),
      running: grouped.fetch("running", 0),
      confirmed: grouped.fetch("confirmed", 0),
      failed: grouped.fetch("failed", 0),
      deleted: grouped.fetch("deleted", 0),
      unmonitored: grouped.fetch("unmonitored", 0),
      tagged: grouped.fetch("tagged", 0)
    }
  end
end
