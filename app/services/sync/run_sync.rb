module Sync
  class RunSync
    PHASES = {
      sonarr_inventory: Sync::SonarrInventorySync,
      radarr_inventory: Sync::RadarrInventorySync,
      tautulli_users: Sync::TautulliUsersSync,
      tautulli_history: Sync::TautulliHistorySync,
      tautulli_metadata: Sync::TautulliMetadataSync,
      mapping_risk_detection: Sync::MappingRiskDetectionSync,
      cleanup: Sync::CleanupSync
    }.freeze

    PHASE_LABELS = {
      "sonarr_inventory" => "Sonarr Inventory",
      "radarr_inventory" => "Radarr Inventory",
      "tautulli_users" => "Tautulli Users",
      "tautulli_history" => "Tautulli History",
      "tautulli_metadata" => "Tautulli Metadata",
      "mapping_risk_detection" => "Mapping Risk Detection",
      "cleanup" => "Cleanup"
    }.freeze

    class << self
      def phase_order
        PHASES.keys.map(&:to_s)
      end

      def phase_label_for(phase_name)
        PHASE_LABELS.fetch(phase_name.to_s, phase_name.to_s.humanize)
      end
    end

    def initialize(sync_run:, correlation_id:)
      @sync_run = sync_run
      @correlation_id = correlation_id
    end

    def call
      aggregate_counts = {}

      PHASES.each do |phase_name, service_class|
        phase_counts = run_phase!(phase_name:, service_class:)
        aggregate_counts[phase_name.to_s] = phase_counts
      end

      aggregate_counts
    end

    private

    attr_reader :correlation_id, :sync_run

    def run_phase!(phase_name:, service_class:)
      phase_started_at = Time.current
      sync_run.update!(phase: phase_name.to_s)
      record_phase_started!(phase_name:)
      log_phase_started!(phase_name:)
      RunProgressBroadcaster.broadcast(sync_run: sync_run, correlation_id: correlation_id)

      phase_counts = service_class.new(sync_run:, correlation_id: correlation_id).call

      sync_run.update!(
        phase_counts_json: sync_run.phase_counts_json.merge(phase_name.to_s => phase_counts)
      )
      record_phase_completed!(phase_name:, phase_counts:)
      log_phase_completed!(phase_name:, phase_counts:, phase_started_at:)
      RunProgressBroadcaster.broadcast(sync_run: sync_run, correlation_id: correlation_id)
      phase_counts
    end

    def record_phase_started!(phase_name:)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.sync.phase_started",
        correlation_id: correlation_id,
        actor: nil,
        subject: sync_run,
        payload: {
          sync_run_id: sync_run.id,
          trigger: sync_run.trigger,
          phase: phase_name.to_s
        }
      )
    end

    def record_phase_completed!(phase_name:, phase_counts:)
      AuditEvents::Recorder.record!(
        event_name: "cullarr.sync.phase_completed",
        correlation_id: correlation_id,
        actor: nil,
        subject: sync_run,
        payload: {
          sync_run_id: sync_run.id,
          trigger: sync_run.trigger,
          phase: phase_name.to_s,
          counts: phase_counts
        }
      )
    end

    def log_phase_started!(phase_name:)
      Rails.logger.info(
        [
          "sync_phase_started",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "phase=#{phase_name}",
          "phase_label=#{self.class.phase_label_for(phase_name)}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end

    def log_phase_completed!(phase_name:, phase_counts:, phase_started_at:)
      duration_ms = ((Time.current - phase_started_at) * 1000).round
      Rails.logger.info(
        [
          "sync_phase_completed",
          "sync_run_id=#{sync_run.id}",
          "trigger=#{sync_run.trigger}",
          "phase=#{phase_name}",
          "phase_label=#{self.class.phase_label_for(phase_name)}",
          "duration_ms=#{duration_ms}",
          "counts=#{phase_counts.to_json}",
          "correlation_id=#{correlation_id}"
        ].join(" ")
      )
    end
  end
end
