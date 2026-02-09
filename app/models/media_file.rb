class MediaFile < ApplicationRecord
  belongs_to :attachable, polymorphic: true
  belongs_to :integration

  has_many :deletion_actions, dependent: :restrict_with_exception

  validates :arr_file_id, :path, :path_canonical, :size_bytes, presence: true
  validates :arr_file_id, uniqueness: { scope: :integration_id }
end
