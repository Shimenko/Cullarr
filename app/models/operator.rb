class Operator < ApplicationRecord
  has_secure_password

  has_many :audit_events, dependent: :nullify
  has_many :delete_mode_unlocks, dependent: :destroy
  has_many :deletion_runs, dependent: :destroy

  before_validation :normalize_email

  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validate :single_operator_record, on: :create

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end

  def single_operator_record
    return unless self.class.exists?

    errors.add(:base, "Only one operator account is allowed")
  end
end
