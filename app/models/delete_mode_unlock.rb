require "openssl"

class DeleteModeUnlock < ApplicationRecord
  DIGEST_ALGORITHM = "SHA256".freeze

  belongs_to :operator

  scope :active, -> { where(used_at: nil).where("expires_at > ?", Time.current) }

  validates :expires_at, :token_digest, presence: true
  validates :token_digest, uniqueness: true

  class << self
    def digest_for(token:, secret:)
      OpenSSL::HMAC.hexdigest(DIGEST_ALGORITHM, secret.to_s, token.to_s)
    end

    def find_by_token(token:, secret:)
      return if token.blank? || secret.blank?

      find_by(token_digest: digest_for(token:, secret:))
    end
  end

  def active?
    !expired? && used_at.nil?
  end

  def expired?
    expires_at <= Time.current
  end
end
