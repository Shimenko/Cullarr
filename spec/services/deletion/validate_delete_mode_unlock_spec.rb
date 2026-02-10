require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Deletion::ValidateDeleteModeUnlock, type: :service do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let(:operator) { create_operator! }
  let(:secret) { "top-secret" }
  let(:env) do
    {
      "CULLARR_DELETE_MODE_ENABLED" => "true",
      "CULLARR_DELETE_MODE_SECRET" => secret
    }
  end

  it "returns success for a valid active unlock token for the same operator" do
    token = "valid-unlock-token"
    unlock = DeleteModeUnlock.create!(
      operator: operator,
      token_digest: DeleteModeUnlock.digest_for(token: token, secret: secret),
      expires_at: 20.minutes.from_now
    )

    result = described_class.new(
      token: token,
      operator: operator,
      correlation_id: "corr-unlock-validate-success",
      env: env
    ).call

    expect(result.success?).to be(true)
    expect(result.unlock).to eq(unlock)
  end

  it "returns delete_unlock_required when token is missing" do
    result = described_class.new(
      token: nil,
      operator: operator,
      correlation_id: "corr-unlock-validate-required",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("delete_unlock_required")
  end

  it "returns delete_unlock_invalid when digest lookup misses" do
    result = described_class.new(
      token: "missing-token",
      operator: operator,
      correlation_id: "corr-unlock-validate-invalid",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("delete_unlock_invalid")
  end

  it "returns delete_unlock_expired for expired unlocks" do
    token = "expired-token"
    DeleteModeUnlock.create!(
      operator: operator,
      token_digest: DeleteModeUnlock.digest_for(token: token, secret: secret),
      expires_at: 1.minute.ago
    )

    result = described_class.new(
      token: token,
      operator: operator,
      correlation_id: "corr-unlock-validate-expired",
      env: env
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("delete_unlock_expired")
  end

  it "returns delete_mode_disabled when delete mode is disabled" do
    result = described_class.new(
      token: "token",
      operator: operator,
      correlation_id: "corr-unlock-validate-disabled",
      env: env.merge("CULLARR_DELETE_MODE_ENABLED" => "false")
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("delete_mode_disabled")
  end
end
# rubocop:enable RSpec/ExampleLength
