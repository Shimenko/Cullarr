class Series < ApplicationRecord
  belongs_to :integration

  has_many :seasons, dependent: :destroy
  has_many :keep_markers, as: :keepable, dependent: :destroy

  validates :sonarr_series_id, :title, presence: true
  validates :sonarr_series_id, uniqueness: { scope: :integration_id }
end
