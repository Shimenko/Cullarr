require "rails_helper"

RSpec.describe DeleteModeUnlock, type: :model do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  describe ".digest_for" do
    it "builds deterministic HMAC digests" do
      digest_a = described_class.digest_for(token: "raw-token", secret: "top-secret")
      digest_b = described_class.digest_for(token: "raw-token", secret: "top-secret")
      digest_c = described_class.digest_for(token: "raw-token", secret: "different-secret")

      expect(digest_a).to eq(digest_b)
      expect(digest_a).not_to eq(digest_c)
      expect(digest_a.length).to eq(64)
    end
  end

  describe ".find_by_token" do
    it "finds a record by raw token and secret" do
      operator = create_operator!
      token = "unlock-token"
      secret = "top-secret"
      unlock = described_class.create!(
        operator: operator,
        token_digest: described_class.digest_for(token: token, secret: secret),
        expires_at: 30.minutes.from_now
      )

      found = described_class.find_by_token(token: token, secret: secret)

      expect(found).to eq(unlock)
    end

    it "returns nil when token or secret does not match" do
      operator = create_operator!
      token = "unlock-token"
      secret = "top-secret"
      described_class.create!(
        operator: operator,
        token_digest: described_class.digest_for(token: token, secret: secret),
        expires_at: 30.minutes.from_now
      )

      expect(described_class.find_by_token(token: token, secret: "wrong-secret")).to be_nil
      expect(described_class.find_by_token(token: "wrong-token", secret: secret)).to be_nil
    end
  end

  describe "#active?" do
    it "returns true only when unexpired and unused" do
      operator = create_operator!
      unlock = described_class.create!(
        operator: operator,
        token_digest: described_class.digest_for(token: "unlock-token", secret: "top-secret"),
        expires_at: 10.minutes.from_now
      )

      expect(unlock.active?).to be(true)
      expect(unlock.expired?).to be(false)

      unlock.update!(used_at: Time.current)
      expect(unlock.active?).to be(false)
    end
  end
end
