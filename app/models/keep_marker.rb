class KeepMarker < ApplicationRecord
  belongs_to :keepable, polymorphic: true

  validates :keepable_id, uniqueness: { scope: :keepable_type }
end
