require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Retention::Prune do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-02-11 12:00:00 UTC") }

  def create_setting(key, value)
    AppSetting.find_or_initialize_by(key: key).tap do |setting|
      setting.value_json = value
      setting.save!
    end
  end

  def create_deletion_action!(deletion_run:, integration:, media_file:, status:)
    DeletionAction.create!(
      deletion_run: deletion_run,
      integration: integration,
      media_file: media_file,
      status: status,
      idempotency_key: SecureRandom.uuid,
      retry_count: 0,
      stage_timestamps_json: {}
    )
  end

  around do |example|
    travel_to(now) { example.run }
  end

  it "prunes terminal run history while keeping active rows" do
    create_setting("retention_sync_runs_days", 180)
    create_setting("retention_deletion_runs_days", 730)
    create_setting("retention_audit_events_days", 365)

    old_time = now - 800.days

    old_sync = SyncRun.create!(status: "success", trigger: "manual", finished_at: old_time)
    active_sync = SyncRun.create!(status: "running", trigger: "manual", started_at: old_time)

    operator = Operator.create!(
      email: "retention@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    integration = Integration.create!(
      kind: "radarr",
      name: "Retention Radarr",
      base_url: "https://radarr.local",
      api_key: "api-key"
    )
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 9001,
      title: "Retention Movie",
      year: 2024
    )
    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 555,
      path: "/data/movies/retention.mkv",
      path_canonical: "/mnt/movies/retention.mkv",
      size_bytes: 123_456
    )

    old_deletion_run = DeletionRun.create!(
      operator: operator,
      scope: "movie",
      status: "success",
      selected_plex_user_ids_json: [],
      summary_json: {},
      finished_at: old_time
    )
    old_action = create_deletion_action!(
      deletion_run: old_deletion_run,
      integration: integration,
      media_file: media_file,
      status: "confirmed"
    )

    active_deletion_run = DeletionRun.create!(
      operator: operator,
      scope: "movie",
      status: "running",
      selected_plex_user_ids_json: [],
      summary_json: {},
      started_at: old_time
    )
    active_action = create_deletion_action!(
      deletion_run: active_deletion_run,
      integration: integration,
      media_file: media_file,
      status: "running"
    )

    old_audit = AuditEvent.create!(
      operator: operator,
      event_name: "cullarr.sync.run_succeeded",
      correlation_id: "corr-old",
      subject_type: "SyncRun",
      subject_id: old_sync.id,
      payload_json: {},
      occurred_at: old_time
    )
    fresh_audit = AuditEvent.create!(
      operator: operator,
      event_name: "cullarr.sync.run_started",
      correlation_id: "corr-fresh",
      subject_type: "SyncRun",
      subject_id: active_sync.id,
      payload_json: {},
      occurred_at: now
    )

    result = described_class.new(correlation_id: "corr-retention-prune", now: now).call

    expect(result.sync_runs_deleted).to eq(1)
    expect(result.deletion_runs_deleted).to eq(1)
    expect(result.deletion_actions_deleted).to eq(1)
    expect(result.audit_events_deleted).to eq(1)
    expect(result.correlation_id).to eq("corr-retention-prune")

    expect(SyncRun.exists?(old_sync.id)).to be(false)
    expect(SyncRun.exists?(active_sync.id)).to be(true)
    expect(DeletionRun.exists?(old_deletion_run.id)).to be(false)
    expect(DeletionAction.exists?(old_action.id)).to be(false)
    expect(DeletionRun.exists?(active_deletion_run.id)).to be(true)
    expect(DeletionAction.exists?(active_action.id)).to be(true)
    expect(AuditEvent.exists?(old_audit.id)).to be(false)
    expect(AuditEvent.exists?(fresh_audit.id)).to be(true)
  end

  it "keeps all audit events when retention_audit_events_days is zero" do
    create_setting("retention_sync_runs_days", 180)
    create_setting("retention_deletion_runs_days", 730)
    create_setting("retention_audit_events_days", 0)

    operator = Operator.create!(
      email: "audit-retention@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    old_audit = AuditEvent.create!(
      operator: operator,
      event_name: "cullarr.settings.updated",
      correlation_id: "corr-audit",
      subject_type: "AppSetting",
      subject_id: 1,
      payload_json: {},
      occurred_at: now - 2.years
    )

    result = described_class.new(now: now).call

    expect(result.audit_events_deleted).to eq(0)
    expect(AuditEvent.exists?(old_audit.id)).to be(true)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
