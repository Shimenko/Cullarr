class SyncRun < ApplicationRecord
  STATUSES = %w[queued running success failed canceled].freeze
  TRIGGERS = %w[manual scheduler system_bootstrap].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :trigger, inclusion: { in: TRIGGERS }
end
