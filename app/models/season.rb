class Season < ApplicationRecord
  belongs_to :series

  has_many :episodes, dependent: :destroy
  has_many :keep_markers, as: :keepable, dependent: :destroy

  validates :season_number, presence: true, uniqueness: { scope: :series_id }
end
