require "rails_helper"

RSpec.describe Sync::TriggerRun, type: :service do
  before do
    allow(Sync::RunProgressBroadcaster).to receive(:broadcast)
    allow(Sync::ProcessRunJob).to receive(:perform_later)
  end

  after do
    SyncRun.delete_all
    AuditEvent.delete_all
    AppSetting.where(key: SyncRun::ACTIVE_QUEUE_LOCK_KEY).delete_all
  end

  it "coalesces concurrent trigger bursts into a single queued run" do
    states = run_concurrent_triggers(
      burst_size: 10,
      trigger: "manual",
      correlation_id_prefix: "corr-burst"
    )

    expect(states.count(:queued)).to eq(1)
    expect(states.count(:conflict)).to eq(9)
    expect(SyncRun.where(status: "queued").count).to eq(1)
    expect(SyncRun.where(status: "running").count).to eq(0)
  end

  it "does not create duplicate queued runs when a queued run already exists" do
    SyncRun.create!(status: "queued", trigger: "manual")

    states = run_concurrent_triggers(
      burst_size: 8,
      trigger: "manual",
      correlation_id_prefix: "corr-queued"
    )

    expect(states).to all(eq(:conflict))
    expect(SyncRun.where(status: "queued").count).to eq(1)
  end

  def run_concurrent_triggers(burst_size:, trigger:, correlation_id_prefix:)
    ready = Queue.new
    start = Queue.new
    states = Queue.new

    threads = Array.new(burst_size) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          result = described_class.new(
            trigger: trigger,
            correlation_id: "#{correlation_id_prefix}-#{index}",
            actor: nil
          ).call
          states << result.state
        end
      end
    end

    burst_size.times { ready.pop }
    burst_size.times { start << true }
    threads.each(&:value)

    Array.new(burst_size) { states.pop }
  end
end
