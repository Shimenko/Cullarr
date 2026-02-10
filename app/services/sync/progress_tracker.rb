module Sync
  class ProgressTracker
    PROGRESS_KEY = "_progress".freeze
    VERSION = 1

    class << self
      def bootstrap!(sync_run:)
        phase_counts = sync_run.phase_counts_json.deep_dup
        progress = normalize_progress_hash(phase_counts[PROGRESS_KEY])
        progress["phases"] = build_phases(progress.fetch("phases", {}))
        progress["updated_at"] = Time.current.iso8601
        phase_counts[PROGRESS_KEY] = progress
        sync_run.update!(phase_counts_json: phase_counts)
      end

      def progress_data_for(sync_run)
        normalize_progress_hash(sync_run.phase_counts_json[PROGRESS_KEY])
      end

      def build_phases(existing_phases)
        Sync::RunSync.phase_order.each_with_object({}) do |phase_name, result|
          phase_data = normalize_phase_hash(existing_phases[phase_name])
          result[phase_name] = default_phase_data(phase_name).merge(phase_data)
        end
      end

      def normalize_progress_hash(value)
        normalized = (value || {}).deep_stringify_keys
        normalized["version"] ||= VERSION
        normalized["phases"] = (normalized["phases"] || {}).deep_stringify_keys
        normalized
      end

      def normalize_phase_hash(value)
        (value || {}).deep_stringify_keys
      end

      def default_phase_data(phase_name)
        {
          "label" => Sync::RunSync.phase_label_for(phase_name),
          "state" => "pending",
          "total_units" => 0,
          "processed_units" => 0
        }
      end
    end

    def initialize(sync_run:, correlation_id:, phase_name:, broadcast_every: 25)
      @sync_run = sync_run
      @correlation_id = correlation_id
      @phase_name = phase_name.to_s
      @broadcast_every = [ broadcast_every.to_i, 1 ].max
      @pending_processed_delta = 0
      @last_flush_at = nil
      self.class.bootstrap!(sync_run:)
    end

    def start!
      update_phase!(force_broadcast: true) do |phase_data|
        phase_data["state"] = "current"
        phase_data["started_at"] ||= Time.current.iso8601
      end
    end

    def add_total!(count)
      count = count.to_i
      return if count <= 0

      update_phase!(force_broadcast: true) do |phase_data|
        phase_data["total_units"] = phase_data.fetch("total_units", 0).to_i + count
      end
    end

    def advance!(count = 1)
      count = count.to_i
      return if count <= 0

      @pending_processed_delta += count
      update_phase!(force_broadcast: force_broadcast?) do |phase_data|
        phase_data["processed_units"] = phase_data.fetch("processed_units", 0).to_i + count
      end
    end

    def complete!
      update_phase!(force_broadcast: true) do |phase_data|
        total_units = phase_data.fetch("total_units", 0).to_i
        if total_units <= 0
          total_units = 1
          phase_data["total_units"] = total_units
        end

        phase_data["processed_units"] = total_units
        phase_data["state"] = "complete"
        phase_data["finished_at"] = Time.current.iso8601
      end
    end

    def fail!
      update_phase!(force_broadcast: true) do |phase_data|
        phase_data["state"] = "failed"
        phase_data["finished_at"] = Time.current.iso8601
      end
    end

    private

    attr_reader :broadcast_every, :correlation_id, :phase_name, :sync_run

    def force_broadcast?
      return true if @pending_processed_delta >= broadcast_every
      return true if @last_flush_at.blank?

      (Time.current - @last_flush_at) >= 1.0
    end

    def update_phase!(force_broadcast:)
      phase_counts = sync_run.phase_counts_json.deep_dup
      progress = self.class.normalize_progress_hash(phase_counts[PROGRESS_KEY])
      phases = self.class.build_phases(progress.fetch("phases", {}))
      phase_data = phases.fetch(phase_name)

      yield(phase_data)

      total_units = [ phase_data.fetch("total_units", 0).to_i, 0 ].max
      processed_units = [ phase_data.fetch("processed_units", 0).to_i, 0 ].max
      if total_units.positive? && processed_units > total_units
        phase_data["processed_units"] = total_units
      end

      progress["phases"] = phases
      progress["updated_at"] = Time.current.iso8601
      phase_counts[PROGRESS_KEY] = progress
      sync_run.update!(phase_counts_json: phase_counts)

      return unless force_broadcast

      @pending_processed_delta = 0
      @last_flush_at = Time.current
      Sync::RunProgressBroadcaster.broadcast(sync_run:, correlation_id:)
    end
  end
end
