require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Sync::ProcessRun, type: :service do
  before do
    allow(Sync::RunProgressBroadcaster).to receive(:broadcast)
  end

  it "records run_started and run_succeeded payload fields with correlation id" do
    sync_run = SyncRun.create!(status: "queued", trigger: "manual")
    run_sync = instance_double(Sync::RunSync, call: { "sonarr_inventory" => { "series_fetched" => 1 } })
    allow(Sync::RunSync).to receive(:new).with(sync_run:, correlation_id: "corr-process-success").and_return(run_sync)

    described_class.new(sync_run:, correlation_id: "corr-process-success").call

    expect(sync_run.reload.status).to eq("success")
    started_event = AuditEvent.find_by!(event_name: "cullarr.sync.run_started", subject_type: "SyncRun", subject_id: sync_run.id)
    succeeded_event = AuditEvent.find_by!(event_name: "cullarr.sync.run_succeeded", subject_type: "SyncRun", subject_id: sync_run.id)
    started_payload = started_event.payload_json.with_indifferent_access
    succeeded_payload = succeeded_event.payload_json.with_indifferent_access

    expect(started_event.correlation_id).to eq("corr-process-success")
    expect(started_payload).to include(sync_run_id: sync_run.id, trigger: "manual")
    expect(succeeded_payload).to include(sync_run_id: sync_run.id, trigger: "manual")
    expect(succeeded_payload.fetch(:phase_counts)).to eq({ "sonarr_inventory" => { "series_fetched" => 1 } })
  end

  {
    Integrations::UnsupportedVersionError.new("unsupported", details: { reported_version: "3.0.0" }) => "unsupported_integration_version",
    Integrations::RateLimitedError.new("rate limited") => "rate_limited",
    Integrations::AuthError.new("auth failed") => "integration_auth_failed",
    Integrations::ContractMismatchError.new("shape mismatch") => "integration_contract_mismatch",
    Integrations::ConnectivityError.new("unreachable") => "integration_unreachable"
  }.each do |error, expected_code|
    it "maps #{error.class.name.demodulize} failures to #{expected_code}" do
      sync_run = SyncRun.create!(status: "queued", trigger: "manual")
      run_sync = instance_double(Sync::RunSync)
      allow(Sync::RunSync).to receive(:new).with(sync_run:, correlation_id: "corr-process-failure").and_return(run_sync)
      allow(run_sync).to receive(:call).and_raise(error)

      described_class.new(sync_run:, correlation_id: "corr-process-failure").call

      failed_run = sync_run.reload
      failed_event = AuditEvent.find_by!(
        event_name: "cullarr.sync.run_failed",
        subject_type: "SyncRun",
        subject_id: sync_run.id
      )
      failed_payload = failed_event.payload_json.with_indifferent_access

      expect(failed_run.status).to eq("failed")
      expect(failed_run.error_code).to eq(expected_code)
      expect(failed_payload).to include(sync_run_id: sync_run.id, trigger: "manual", error_code: expected_code)
      expect(failed_payload.fetch(:error_message)).to eq(error.message)
    end
  end

  it "maps unknown errors to sync_phase_failed" do
    sync_run = SyncRun.create!(status: "queued", trigger: "manual")
    run_sync = instance_double(Sync::RunSync)
    allow(Sync::RunSync).to receive(:new).with(sync_run:, correlation_id: "corr-process-unknown").and_return(run_sync)
    allow(run_sync).to receive(:call).and_raise(StandardError, "boom")

    described_class.new(sync_run:, correlation_id: "corr-process-unknown").call

    failed_run = sync_run.reload
    failed_event = AuditEvent.find_by!(event_name: "cullarr.sync.run_failed", subject_type: "SyncRun", subject_id: sync_run.id)
    failed_payload = failed_event.payload_json.with_indifferent_access

    expect(failed_run.status).to eq("failed")
    expect(failed_run.error_code).to eq("sync_phase_failed")
    expect(failed_payload.fetch(:error_code)).to eq("sync_phase_failed")
  end

  it "preserves queued-next trigger lineage when creating the follow-up run" do
    sync_run = SyncRun.create!(status: "queued", trigger: "scheduler", queued_next: true)
    run_sync = instance_double(Sync::RunSync, call: {})
    allow(Sync::RunSync).to receive(:new).with(sync_run:, correlation_id: "corr-process-lineage").and_return(run_sync)

    AuditEvent.create!(
      event_name: "cullarr.sync.run_queued_next",
      subject_type: "SyncRun",
      subject_id: sync_run.id,
      correlation_id: "corr-process-lineage",
      payload_json: { "trigger" => "manual" },
      occurred_at: Time.current
    )

    described_class.new(sync_run:, correlation_id: "corr-process-lineage").call

    follow_up_run = SyncRun.recent_first.first
    expect(follow_up_run.id).not_to eq(sync_run.id)
    expect(follow_up_run.status).to eq("queued")
    expect(follow_up_run.trigger).to eq("manual")
  end

  it "records run_skipped when a non-queued run is picked up" do
    sync_run = SyncRun.create!(status: "running", trigger: "manual", started_at: 2.minutes.ago)

    described_class.new(sync_run:, correlation_id: "corr-process-skipped").call

    skipped_event = AuditEvent.find_by!(
      event_name: "cullarr.sync.run_skipped",
      subject_type: "SyncRun",
      subject_id: sync_run.id
    )
    payload = skipped_event.payload_json.with_indifferent_access

    expect(sync_run.reload.status).to eq("running")
    expect(payload).to include(
      sync_run_id: sync_run.id,
      trigger: "manual",
      status: "running",
      reason: "not_queued"
    )
  end
end
# rubocop:enable RSpec/ExampleLength
