class Movie < ApplicationRecord
  include MappingState

  belongs_to :integration

  has_many :media_files, as: :attachable, dependent: :destroy
  has_many :watch_stats, as: :watchable, dependent: :destroy
  has_many :keep_markers, as: :keepable, dependent: :destroy

  validates :radarr_movie_id, :title, presence: true
  validates :radarr_movie_id, uniqueness: { scope: :integration_id }
end
