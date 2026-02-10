require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ReceiveMessages
RSpec.describe Deletion::ProcessAction, type: :service do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  def create_integration!
    Integration.create!(
      kind: "radarr",
      name: "Radarr Process Action",
      base_url: "https://radarr.process-action.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
  end

  def with_delete_mode_env
    previous_enabled = ENV["CULLARR_DELETE_MODE_ENABLED"]
    previous_secret = ENV["CULLARR_DELETE_MODE_SECRET"]
    ENV["CULLARR_DELETE_MODE_ENABLED"] = "true"
    ENV["CULLARR_DELETE_MODE_SECRET"] = "top-secret"
    yield
  ensure
    ENV["CULLARR_DELETE_MODE_ENABLED"] = previous_enabled
    ENV["CULLARR_DELETE_MODE_SECRET"] = previous_secret
  end

  def create_movie_file!(integration:, arr_file_id: 1001)
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 9001 + arr_file_id,
      title: "Process Action Movie #{arr_file_id}",
      duration_ms: 100_000
    )
    MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: arr_file_id,
      path: "/media/movies/process-action-#{arr_file_id}.mkv",
      path_canonical: "/media/movies/process-action-#{arr_file_id}.mkv",
      size_bytes: 2.gigabytes
    )
  end

  def create_run_with_action_context!(operator:, media_file:, context:)
    unlock = DeleteModeUnlock.create!(
      operator: operator,
      token_digest: "digest-#{SecureRandom.hex(8)}",
      expires_at: 20.minutes.from_now
    )
    run = DeletionRun.create!(
      operator: operator,
      status: "queued",
      scope: "movie",
      selected_plex_user_ids_json: [],
      summary_json: {
        "delete_mode_unlock_id" => unlock.id,
        "action_context" => { media_file.id.to_s => context }
      }
    )

    DeletionAction.create!(
      deletion_run: run,
      media_file: media_file,
      integration: media_file.integration,
      idempotency_key: "integration:#{media_file.integration_id}:file:#{media_file.arr_file_id}",
      status: "queued",
      stage_timestamps_json: {}
    )
  end

  it "executes delete -> unmonitor -> tag -> confirm and marks media file as culled" do
    with_delete_mode_env do
      operator = create_operator!
      integration = create_integration!
      media_file = create_movie_file!(integration: integration, arr_file_id: 1111)
      action = create_run_with_action_context!(
        operator: operator,
        media_file: media_file,
        context: {
          "should_unmonitor" => true,
          "unmonitor_kind" => "movie",
          "unmonitor_target_id" => media_file.attachable.radarr_movie_id,
          "should_tag" => true,
          "tag_kind" => "movie",
          "tag_target_id" => media_file.attachable.radarr_movie_id
        }
      )

      adapter = instance_spy(Integrations::RadarrAdapter)
      allow(Integrations::AdapterFactory).to receive(:for).with(integration: integration).and_return(adapter)
      allow(adapter).to receive(:delete_movie_file!).and_return(deleted: true)
      allow(adapter).to receive(:unmonitor_movie!).and_return(updated: true)
      allow(adapter).to receive(:ensure_tag!).and_return(arr_tag_id: 44)
      allow(adapter).to receive(:add_movie_tag!).and_return(updated: true)
      allow(adapter).to receive(:fetch_movie_files).and_return([])

      described_class.new(deletion_action: action, correlation_id: "corr-process-action-success").call

      expect(adapter).to have_received(:delete_movie_file!).with(arr_file_id: media_file.arr_file_id).ordered
      expect(adapter).to have_received(:unmonitor_movie!).with(radarr_movie_id: media_file.attachable.radarr_movie_id).ordered
      expect(adapter).to have_received(:ensure_tag!).with(name: "cullarr:culled").ordered
      expect(adapter).to have_received(:add_movie_tag!).with(radarr_movie_id: media_file.attachable.radarr_movie_id, arr_tag_id: 44).ordered
      expect(adapter).to have_received(:fetch_movie_files).ordered
      expect(action.reload.status).to eq("confirmed")
      expect(action.error_code).to be_nil
      expect(action.warning_codes).to eq([])
      expect(media_file.reload.culled_at).to be_present
    end
  end

  it "fails action when delete fails and does not run unmonitor or tag stages" do
    with_delete_mode_env do
      operator = create_operator!
      integration = create_integration!
      media_file = create_movie_file!(integration: integration, arr_file_id: 2222)
      action = create_run_with_action_context!(
        operator: operator,
        media_file: media_file,
        context: {
          "should_unmonitor" => true,
          "unmonitor_kind" => "movie",
          "unmonitor_target_id" => media_file.attachable.radarr_movie_id,
          "should_tag" => true,
          "tag_kind" => "movie",
          "tag_target_id" => media_file.attachable.radarr_movie_id
        }
      )

      adapter = instance_spy(Integrations::RadarrAdapter)
      allow(Integrations::AdapterFactory).to receive(:for).with(integration: integration).and_return(adapter)
      allow(adapter).to receive(:delete_movie_file!).and_raise(Integrations::AuthError.new("bad credentials"))

      described_class.new(deletion_action: action, correlation_id: "corr-process-action-failed-delete").call

      expect(adapter).not_to have_received(:unmonitor_movie!)
      expect(adapter).not_to have_received(:ensure_tag!)
      expect(adapter).not_to have_received(:add_movie_tag!)
      expect(action.reload.status).to eq("failed")
      expect(action.error_code).to eq("integration_auth_failed")
      expect(media_file.reload.culled_at).to be_nil
    end
  end

  it "treats tag failures as non-fatal warnings and still confirms deletion" do
    with_delete_mode_env do
      operator = create_operator!
      integration = create_integration!
      media_file = create_movie_file!(integration: integration, arr_file_id: 3333)
      action = create_run_with_action_context!(
        operator: operator,
        media_file: media_file,
        context: {
          "should_unmonitor" => false,
          "should_tag" => true,
          "tag_kind" => "movie",
          "tag_target_id" => media_file.attachable.radarr_movie_id
        }
      )

      adapter = instance_spy(Integrations::RadarrAdapter)
      allow(Integrations::AdapterFactory).to receive(:for).with(integration: integration).and_return(adapter)
      allow(adapter).to receive(:delete_movie_file!).and_return(deleted: true)
      allow(adapter).to receive(:fetch_movie_files).and_return([])
      allow(adapter).to receive(:ensure_tag!).and_raise(Integrations::ConnectivityError.new("integration unreachable"))

      described_class.new(deletion_action: action, correlation_id: "corr-process-action-tag-warning").call

      expect(adapter).not_to have_received(:add_movie_tag!)
      expect(action.reload.status).to eq("confirmed")
      expect(action.warning_codes).to include("integration_unreachable")
      expect(media_file.reload.culled_at).to be_present
    end
  end

  it "fails precheck when integration is unsupported for delete operations" do
    with_delete_mode_env do
      operator = create_operator!
      integration = create_integration!
      integration.update!(settings_json: integration.settings_json.merge("supported_for_delete" => false))
      media_file = create_movie_file!(integration: integration, arr_file_id: 4444)
      action = create_run_with_action_context!(
        operator: operator,
        media_file: media_file,
        context: {
          "should_unmonitor" => true,
          "unmonitor_kind" => "movie",
          "unmonitor_target_id" => media_file.attachable.radarr_movie_id,
          "should_tag" => false
        }
      )

      adapter = instance_spy(Integrations::RadarrAdapter)
      allow(Integrations::AdapterFactory).to receive(:for).with(integration: integration).and_return(adapter)

      described_class.new(deletion_action: action, correlation_id: "corr-process-action-unsupported").call

      expect(adapter).not_to have_received(:delete_movie_file!)
      expect(action.reload.status).to eq("failed")
      expect(action.error_code).to eq("unsupported_integration_version")
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ReceiveMessages
