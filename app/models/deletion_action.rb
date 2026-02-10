class DeletionAction < ApplicationRecord
  STATUSES = %w[queued running deleted unmonitored tagged confirmed failed].freeze
  STAGES = %w[precheck delete_file unmonitor tag confirm_resync].freeze

  belongs_to :deletion_run
  belongs_to :integration
  belongs_to :media_file

  validates :idempotency_key, presence: true, uniqueness: { scope: :integration_id }
  validates :status, inclusion: { in: STATUSES }

  def warning_codes
    Array(stage_timestamps_json["warning_codes"]).map(&:to_s).reject(&:blank?).uniq
  end

  def as_api_json
    {
      id: id,
      media_file_id: media_file_id,
      integration_id: integration_id,
      status: status,
      error_code: error_code,
      error_message: error_message,
      retry_count: retry_count,
      warning_codes: warning_codes,
      stage_timestamps: stage_timestamps_json.except("warning_codes"),
      started_at: started_at,
      finished_at: finished_at
    }
  end
end
