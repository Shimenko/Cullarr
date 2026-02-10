require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Deletion::IssueDeleteModeUnlock, type: :service do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let(:operator) { create_operator! }
  let(:now) { Time.zone.parse("2026-02-10 12:00:00 UTC") }
  let(:base_env) do
    {
      "CULLARR_DELETE_MODE_ENABLED" => "true",
      "CULLARR_DELETE_MODE_SECRET" => "top-secret"
    }
  end

  it "issues a token digest record when delete mode is enabled and password is valid" do
    result = nil

    expect do
      result = described_class.new(
        operator: operator,
        password: "password123",
        correlation_id: "corr-unlock-success",
        env: base_env,
        now: now
      ).call
    end.to change(DeleteModeUnlock, :count).by(1)
      .and change { AuditEvent.where(event_name: "cullarr.security.delete_unlock_granted").count }.by(1)

    unlock = DeleteModeUnlock.last
    expect(result.success?).to be(true)
    expect(result.token).to be_present
    expect(result.expires_at).to eq(now + 15.minutes)
    expect(unlock.token_digest).to eq(DeleteModeUnlock.digest_for(token: result.token, secret: "top-secret"))
    expect(unlock.expires_at).to eq(now + 15.minutes)
  end

  it "returns delete_mode_disabled when the env gate is disabled" do
    result = described_class.new(
      operator: operator,
      password: "password123",
      correlation_id: "corr-unlock-disabled",
      env: base_env.merge("CULLARR_DELETE_MODE_ENABLED" => "false"),
      now: now
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("delete_mode_disabled")
    expect(result.error_message).to eq("Delete mode is disabled.")
    expect(DeleteModeUnlock.count).to eq(0)
    expect(AuditEvent.where(event_name: "cullarr.security.delete_unlock_denied").count).to eq(1)
  end

  it "returns delete_mode_disabled when secret is missing" do
    result = described_class.new(
      operator: operator,
      password: "password123",
      correlation_id: "corr-unlock-secret-missing",
      env: base_env.merge("CULLARR_DELETE_MODE_SECRET" => ""),
      now: now
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("delete_mode_disabled")
    expect(result.error_message).to eq("Delete mode is not configured.")
    expect(DeleteModeUnlock.count).to eq(0)
    expect(AuditEvent.where(event_name: "cullarr.security.delete_unlock_denied").count).to eq(1)
  end

  it "returns forbidden when password verification fails" do
    result = described_class.new(
      operator: operator,
      password: "wrong-password",
      correlation_id: "corr-unlock-invalid-password",
      env: base_env,
      now: now
    ).call

    expect(result.success?).to be(false)
    expect(result.error_code).to eq("forbidden")
    expect(result.error_message).to eq("Password verification failed.")
    expect(DeleteModeUnlock.count).to eq(0)
    expect(AuditEvent.where(event_name: "cullarr.security.delete_unlock_denied").count).to eq(1)
  end

  it "uses configured re-authentication window for expiration" do
    AppSetting.create!(key: "sensitive_action_reauthentication_window_minutes", value_json: 45)

    result = described_class.new(
      operator: operator,
      password: "password123",
      correlation_id: "corr-unlock-window",
      env: base_env,
      now: now
    ).call

    expect(result.success?).to be(true)
    expect(result.expires_at).to eq(now + 45.minutes)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
