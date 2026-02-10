require "rails_helper"

RSpec.describe Sync::ScheduleWindow, type: :service do
  describe "#due?" do
    it "is due when no prior runs exist" do
      window = described_class.new(sync_enabled: true, sync_interval_minutes: 30)

      expect(window.due?).to be(true)
    end

    it "is not due when a run is active" do
      SyncRun.create!(status: "running", trigger: "manual", started_at: Time.current)
      window = described_class.new(sync_enabled: true, sync_interval_minutes: 30)

      expect(window.due?).to be(false)
    end

    it "is not due when the latest attempt is still within interval" do
      SyncRun.create!(
        status: "failed",
        trigger: "scheduler",
        started_at: 10.minutes.ago,
        finished_at: 10.minutes.ago
      )
      window = described_class.new(sync_enabled: true, sync_interval_minutes: 30)

      expect(window.due?).to be(false)
    end

    it "is due when latest attempt is older than interval" do
      SyncRun.create!(
        status: "failed",
        trigger: "scheduler",
        started_at: 2.hours.ago,
        finished_at: 2.hours.ago
      )
      window = described_class.new(sync_enabled: true, sync_interval_minutes: 30)

      expect(window.due?).to be(true)
    end
  end
end
