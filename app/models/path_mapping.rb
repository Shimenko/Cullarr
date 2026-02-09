class PathMapping < ApplicationRecord
  belongs_to :integration

  before_validation :normalize_prefixes

  validates :from_prefix, :to_prefix, presence: true
  validates :from_prefix, uniqueness: {
    scope: %i[integration_id to_prefix],
    case_sensitive: false
  }

  private

  def normalize_prefixes
    self.from_prefix = Paths::Normalizer.normalize(from_prefix)
    self.to_prefix = Paths::Normalizer.normalize(to_prefix)
  end
end
