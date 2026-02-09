class AppSetting < ApplicationRecord
  validates :key, presence: true, uniqueness: true
end
