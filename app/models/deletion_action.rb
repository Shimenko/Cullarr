class DeletionAction < ApplicationRecord
  STATUSES = %w[queued running deleted unmonitored tagged confirmed failed].freeze

  belongs_to :deletion_run
  belongs_to :integration
  belongs_to :media_file

  validates :idempotency_key, presence: true, uniqueness: { scope: :integration_id }
  validates :status, inclusion: { in: STATUSES }
end
