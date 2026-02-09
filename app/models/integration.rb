class Integration < ApplicationRecord
  has_many :arr_tags, dependent: :destroy
  has_many :deletion_actions, dependent: :restrict_with_exception
  has_many :episodes, dependent: :destroy
  has_many :media_files, dependent: :restrict_with_exception
  has_many :movies, dependent: :destroy
  has_many :path_mappings, dependent: :destroy
  has_many :series, dependent: :destroy

  enum :kind, { sonarr: "sonarr", radarr: "radarr", tautulli: "tautulli" }

  validates :api_key_ciphertext, :base_url, :kind, :name, presence: true
  validates :name, uniqueness: true
  validates :verify_ssl, inclusion: { in: [ true, false ] }
end
