class ArrTag < ApplicationRecord
  belongs_to :integration

  validates :arr_tag_id, :name, presence: true
  validates :name, uniqueness: { scope: :integration_id }
  validates :arr_tag_id, uniqueness: { scope: :integration_id }
end
