class Episode < ApplicationRecord
  belongs_to :integration
  belongs_to :season

  has_many :media_files, as: :attachable, dependent: :destroy
  has_many :watch_stats, as: :watchable, dependent: :destroy
  has_many :keep_markers, as: :keepable, dependent: :destroy

  validates :episode_number, :sonarr_episode_id, presence: true
  validates :sonarr_episode_id, uniqueness: { scope: :integration_id }
end
