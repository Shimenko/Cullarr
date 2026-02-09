class WatchStat < ApplicationRecord
  belongs_to :plex_user
  belongs_to :watchable, polymorphic: true

  validates :watchable_id, uniqueness: { scope: %i[plex_user_id watchable_type] }
end
