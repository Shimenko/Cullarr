class PathExclusion < ApplicationRecord
  validates :name, :path_prefix, presence: true
  validates :path_prefix, uniqueness: true
end
