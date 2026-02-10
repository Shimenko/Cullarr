require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe Sync::SchedulerJob, type: :job do
  it "does not trigger when sync is disabled" do
    allow(AppSetting).to receive(:db_value_for).with("sync_enabled").and_return(false)
    allow(AppSetting).to receive(:db_value_for).with("sync_interval_minutes").and_return(30)
    allow(Sync::TriggerRun).to receive(:new)

    described_class.perform_now

    expect(Sync::TriggerRun).not_to have_received(:new)
  end

  it "triggers scheduler run when due" do
    allow(AppSetting).to receive(:db_value_for).with("sync_enabled").and_return(true)
    allow(AppSetting).to receive(:db_value_for).with("sync_interval_minutes").and_return(30)
    trigger = instance_double(Sync::TriggerRun, call: true)
    allow(Sync::TriggerRun).to receive(:new).and_return(trigger)

    described_class.perform_now

    expect(Sync::TriggerRun).to have_received(:new).with(
      trigger: "scheduler",
      correlation_id: kind_of(String),
      actor: nil
    )
  end

  it "does not trigger when the last success is still fresh" do
    allow(AppSetting).to receive(:db_value_for).with("sync_enabled").and_return(true)
    allow(AppSetting).to receive(:db_value_for).with("sync_interval_minutes").and_return(30)
    SyncRun.create!(
      status: "success",
      trigger: "manual",
      started_at: 5.minutes.ago,
      finished_at: 5.minutes.ago
    )
    allow(Sync::TriggerRun).to receive(:new)

    described_class.perform_now

    expect(Sync::TriggerRun).not_to have_received(:new)
  end

  it "does not trigger while a sync run is already running" do
    allow(AppSetting).to receive(:db_value_for).with("sync_enabled").and_return(true)
    allow(AppSetting).to receive(:db_value_for).with("sync_interval_minutes").and_return(30)
    SyncRun.create!(status: "running", trigger: "manual", started_at: Time.current)
    allow(Sync::TriggerRun).to receive(:new)

    described_class.perform_now

    expect(Sync::TriggerRun).not_to have_received(:new)
  end

  it "respects interval backoff even when no successful sync exists yet" do
    allow(AppSetting).to receive(:db_value_for).with("sync_enabled").and_return(true)
    allow(AppSetting).to receive(:db_value_for).with("sync_interval_minutes").and_return(30)
    SyncRun.create!(
      status: "failed",
      trigger: "scheduler",
      started_at: 10.minutes.ago,
      finished_at: 10.minutes.ago
    )
    allow(Sync::TriggerRun).to receive(:new)

    described_class.perform_now

    expect(Sync::TriggerRun).not_to have_received(:new)
  end
end
# rubocop:enable RSpec/ExampleLength
