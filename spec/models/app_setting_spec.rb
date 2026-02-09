require "rails_helper"

RSpec.describe AppSetting, type: :model do
  def env_overrides
    {
      "CULLARR_DELETE_MODE_ENABLED" => "true",
      "CULLARR_DELETE_MODE_SECRET" => "top-secret",
      "CULLARR_IMAGE_PROXY_ALLOWED_HOSTS" => "plex.local, tautulli.local",
      "CULLARR_ALLOWED_INTEGRATION_HOSTS" => "sonarr.local,radarr.local",
      "CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES" => "192.168.1.0/24,10.0.0.0/24"
    }
  end

  describe ".effective_settings" do
    it "returns db and default sources for db-managed settings" do
      described_class.create!(key: "sync_interval_minutes", value_json: 90)

      settings = described_class.effective_settings(env: {})

      expect(settings["sync_interval_minutes"]).to eq(
        value: 90,
        source: "db"
      )
      expect(settings["watched_mode"]).to eq(
        value: "play_count",
        source: "default"
      )
    end

    it "returns the default source for re-authentication window settings" do
      settings = described_class.effective_settings(env: {})

      expect(settings["sensitive_action_reauthentication_window_minutes"]).to eq(
        value: 15,
        source: "default"
      )
    end

    it "applies boolean env-managed values when present" do
      settings = described_class.effective_settings(env: env_overrides)

      expect(settings["delete_mode_enabled"]).to eq(value: true, source: "env")
      expect(settings["delete_mode_secret_present"]).to eq(value: true, source: "env")
    end

    it "parses csv env-managed values when present" do
      settings = described_class.effective_settings(env: env_overrides)

      expect(settings["image_proxy_allowed_hosts"]).to eq(
        value: %w[plex.local tautulli.local],
        source: "env"
      )
    end

    it "parses integration target allow policy values from env" do
      settings = described_class.effective_settings(env: env_overrides)

      expect(settings["integration_allowed_hosts"]).to eq(
        value: %w[sonarr.local radarr.local],
        source: "env"
      )
      expect(settings["integration_allowed_network_ranges"]).to eq(
        value: %w[192.168.1.0/24 10.0.0.0/24],
        source: "env"
      )
    end
  end

  describe ".apply_updates!" do
    it "returns normalized change details for valid updates" do
      changes = described_class.apply_updates!(
        settings: {
          sync_enabled: "false",
          sync_interval_minutes: "120"
        }
      )

      expect(changes).to include(
        "sync_enabled" => { old: true, new: false },
        "sync_interval_minutes" => { old: 30, new: 120 }
      )
    end

    it "persists casted values for valid updates" do
      described_class.apply_updates!(
        settings: {
          sync_enabled: "false",
          sync_interval_minutes: "120"
        }
      )

      expect(described_class.find_by(key: "sync_enabled")&.value_json).to be(false)
      expect(described_class.find_by(key: "sync_interval_minutes")&.value_json).to eq(120)
    end

    it "raises validation errors for unknown keys" do
      expect do
        described_class.apply_updates!(
          settings: {
            does_not_exist: "value"
          }
        )
      end.to raise_error(AppSetting::InvalidSettingError)
    end

    it "raises validation errors for out of range integers" do
      expect do
        described_class.apply_updates!(
          settings: {
            sync_interval_minutes: 0
          }
        )
      end.to raise_error(AppSetting::InvalidSettingError)
    end

    it "requires explicit confirmation for retention_audit_events_days = 0" do
      described_class.create!(key: "retention_audit_events_days", value_json: 90)

      expect do
        described_class.apply_updates!(
          settings: { retention_audit_events_days: 0 }
        )
      end.to raise_error(AppSetting::UnsafeSettingError)
    end

    it "accepts explicit destructive confirmation for retention_audit_events_days = 0" do
      described_class.create!(key: "retention_audit_events_days", value_json: 90)

      changes = described_class.apply_updates!(
        settings: { retention_audit_events_days: 0 },
        destructive_confirmations: { retention_audit_events_days_zero: true }
      )

      expect(changes).to include("retention_audit_events_days" => { old: 90, new: 0 })
      expect(described_class.find_by(key: "retention_audit_events_days")&.value_json).to eq(0)
    end
  end

  describe ".ensure_defaults!" do
    it "creates missing default records idempotently" do
      expect do
        described_class.ensure_defaults!
      end.to change(described_class, :count).by(described_class::DB_DEFINITIONS.size)

      expect do
        described_class.ensure_defaults!
      end.not_to change(described_class, :count)
    end
  end
end
