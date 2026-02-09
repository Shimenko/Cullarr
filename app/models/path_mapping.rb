class PathMapping < ApplicationRecord
  belongs_to :integration

  validates :from_prefix, :to_prefix, presence: true
  validates :from_prefix, uniqueness: { scope: %i[integration_id to_prefix] }
end
