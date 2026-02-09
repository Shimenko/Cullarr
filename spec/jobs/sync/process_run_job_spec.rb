require "rails_helper"

RSpec.describe Sync::ProcessRunJob, type: :job do
  before do
    allow(Sync::RunProgressBroadcaster).to receive(:broadcast)
  end

  it "marks queued runs as successful and records sync lifecycle events" do
    sync_run = SyncRun.create!(status: "queued", trigger: "manual")

    described_class.perform_now(sync_run.id, "corr-sync-job")

    sync_run.reload
    expect(sync_run.status).to eq("success")
    expect([ sync_run.started_at, sync_run.finished_at ]).to all(be_present)
    expect(sync_run.phase).to eq("complete")
    expect(AuditEvent.where(event_name: "cullarr.sync.run_started", subject_type: "SyncRun", subject_id: sync_run.id)).to exist
    expect(AuditEvent.where(event_name: "cullarr.sync.run_succeeded", subject_type: "SyncRun", subject_id: sync_run.id)).to exist
  end

  it "queues a follow-up run when queued_next is set on the active run" do
    sync_run = SyncRun.create!(status: "queued", trigger: "manual", queued_next: true)

    expect do
      described_class.perform_now(sync_run.id, "corr-next")
    end.to change(SyncRun, :count).by(1)

    sync_run.reload
    queued_follow_up = SyncRun.recent_first.first
    expect(sync_run.queued_next).to be(false)
    expect(queued_follow_up.status).to eq("queued")
    expect(queued_follow_up.trigger).to eq("manual")
    expect(queued_follow_up.id).not_to eq(sync_run.id)
  end

  it "is a no-op when the run id no longer exists" do
    expect { described_class.perform_now(-1, "corr-missing") }.not_to raise_error
  end
end
