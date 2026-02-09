class PathExclusion < ApplicationRecord
  before_validation :normalize_path_prefix

  validates :name, :path_prefix, presence: true
  validates :path_prefix, uniqueness: { case_sensitive: false }

  private

  def normalize_path_prefix
    self.path_prefix = Paths::Normalizer.normalize(path_prefix)
    self.name = name.to_s.strip
  end
end
