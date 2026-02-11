require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Sync::RecoverStaleRuns, type: :service do
  before do
    allow(Sync::RunProgressBroadcaster).to receive(:broadcast)
    allow(Sync::ProcessRunJob).to receive(:perform_later)
  end

  after do
    AppSetting.where(key: SyncRun::ACTIVE_QUEUE_LOCK_KEY).delete_all
  end

  it "marks stale running runs as failed when no active process job exists" do
    sync_run = SyncRun.create!(status: "running", trigger: "manual", started_at: 8.minutes.ago)
    sync_run.touch(time: 5.minutes.ago)
    service = described_class.new(correlation_id: "corr-recover", actor: nil, stale_after: 60.seconds)
    allow(service).to receive(:active_running_run_ids_from_queue).and_return([])

    result = service.call

    recovered_run = sync_run.reload
    recovered_event = AuditEvent.find_by!(
      event_name: "cullarr.sync.run_recovered_stale",
      subject_type: "SyncRun",
      subject_id: sync_run.id
    )
    recovered_payload = recovered_event.payload_json.with_indifferent_access

    expect(result.stale_run_ids).to eq([ sync_run.id ])
    expect(result.requeued_run_ids).to eq([])
    expect(recovered_run.status).to eq("failed")
    expect(recovered_run.error_code).to eq("worker_lost")
    expect(recovered_run.error_message).to include("worker stopped before completion")
    expect(recovered_run.finished_at).to be_present
    expect(recovered_payload).to include(
      sync_run_id: sync_run.id,
      previous_status: "running",
      recovered_status: "failed",
      recovery_error_code: "worker_lost"
    )
  end

  it "does not mark stale runs failed when an unfinished process job exists for the same run" do
    sync_run = SyncRun.create!(status: "running", trigger: "manual", started_at: 8.minutes.ago)
    sync_run.touch(time: 5.minutes.ago)
    service = described_class.new(correlation_id: "corr-active-job", actor: nil, stale_after: 60.seconds)
    allow(service).to receive(:active_running_run_ids_from_queue).and_return([ sync_run.id ])

    result = service.call

    expect(result.stale_run_ids).to eq([])
    expect(result.requeued_run_ids).to eq([])
    expect(sync_run.reload.status).to eq("running")
  end

  it "derives active run ids only from claimed jobs on live processes" do
    service = described_class.new(correlation_id: "corr-active-query", actor: nil, stale_after: 60.seconds)

    allow(service).to receive_messages(queue_tables_available?: true, active_running_queue_arguments: [
      { "arguments" => [ 11 ] },
      { "arguments" => [ 11 ] },
      { "arguments" => [ 42 ] }
    ])

    expect(service.send(:active_running_run_ids_from_queue)).to eq([ 11, 42 ])
  end

  it "returns no active run ids when queue tables are unavailable" do
    service = described_class.new(correlation_id: "corr-no-queue", actor: nil, stale_after: 60.seconds)
    allow(service).to receive(:queue_tables_available?).and_return(false)

    expect(service.send(:active_running_run_ids_from_queue)).to eq([])
  end

  it "requeues a replacement run when stale runs were recovered and no queued run exists" do
    stale_run = SyncRun.create!(status: "running", trigger: "manual", started_at: 8.minutes.ago)
    stale_run.touch(time: 5.minutes.ago)
    service = described_class.new(
      correlation_id: "corr-requeue",
      actor: nil,
      enqueue_replacement: true,
      stale_after: 60.seconds
    )
    allow(service).to receive(:active_running_run_ids_from_queue).and_return([])

    result = service.call

    expect(result.stale_run_ids).to eq([ stale_run.id ])
    expect(result.requeued_run_ids.size).to eq(1)
    queued_replacement = SyncRun.find(result.requeued_run_ids.first)
    queued_event = AuditEvent.find_by!(
      event_name: "cullarr.sync.run_queued",
      subject_type: "SyncRun",
      subject_id: queued_replacement.id
    )
    queued_payload = queued_event.payload_json.with_indifferent_access

    expect(queued_replacement.status).to eq("queued")
    expect(queued_replacement.trigger).to eq("system_bootstrap")
    expect(queued_payload).to include(
      sync_run_id: queued_replacement.id,
      trigger: "system_bootstrap",
      recovered_from_sync_run_id: stale_run.id
    )
    expect(Sync::ProcessRunJob).to have_received(:perform_later).with(queued_replacement.id, "corr-requeue")
  end

  it "does not enqueue a replacement run when one is already queued" do
    stale_run = SyncRun.create!(status: "running", trigger: "manual", started_at: 8.minutes.ago)
    stale_run.touch(time: 5.minutes.ago)
    existing_queued = SyncRun.create!(status: "queued", trigger: "manual")
    service = described_class.new(
      correlation_id: "corr-requeue-conflict",
      actor: nil,
      enqueue_replacement: true,
      stale_after: 60.seconds
    )
    allow(service).to receive(:active_running_run_ids_from_queue).and_return([])

    result = service.call

    expect(result.stale_run_ids).to eq([ stale_run.id ])
    expect(result.requeued_run_ids).to eq([])
    expect(existing_queued.reload.status).to eq("queued")
    expect(Sync::ProcessRunJob).not_to have_received(:perform_later)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
