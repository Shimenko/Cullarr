class KeepMarker < ApplicationRecord
  ALLOWED_KEEPABLE_TYPES = %w[Movie Series Season Episode].freeze

  belongs_to :keepable, polymorphic: true

  validates :keepable_type, inclusion: { in: ALLOWED_KEEPABLE_TYPES }
  validates :keepable_id, presence: true
  validates :keepable_id, uniqueness: { scope: :keepable_type }
  validate :keepable_must_exist

  private

  def keepable_must_exist
    return if keepable_type.blank? || keepable_id.blank?

    model = keepable_type.safe_constantize
    unless model && model < ApplicationRecord && model.exists?(keepable_id)
      errors.add(:keepable_id, "must reference an existing record")
    end
  end
end
