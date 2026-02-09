class PlexUser < ApplicationRecord
  has_many :watch_stats, dependent: :destroy

  validates :friendly_name, :tautulli_user_id, presence: true
  validates :tautulli_user_id, uniqueness: true
end
