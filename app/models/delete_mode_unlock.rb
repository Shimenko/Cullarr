class DeleteModeUnlock < ApplicationRecord
  belongs_to :operator

  validates :expires_at, :token_digest, presence: true
  validates :token_digest, uniqueness: true

  def expired?
    expires_at <= Time.current
  end
end
