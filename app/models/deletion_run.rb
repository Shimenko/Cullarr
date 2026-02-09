class DeletionRun < ApplicationRecord
  STATUSES = %w[queued running success partial_failure failed canceled].freeze
  SCOPES = %w[movie tv_show tv_season tv_episode].freeze

  belongs_to :operator

  has_many :deletion_actions, dependent: :destroy

  validates :scope, inclusion: { in: SCOPES }
  validates :status, inclusion: { in: STATUSES }
end
