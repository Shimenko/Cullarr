class AuditEvent < ApplicationRecord
  belongs_to :operator, optional: true

  validates :event_name, :occurred_at, presence: true
end
