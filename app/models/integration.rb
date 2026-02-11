require "etc"

class Integration < ApplicationRecord
  COMPATIBILITY_MODES = %w[strict_latest warn_only_read_only].freeze
  WORKER_COUNT_MAX = 64
  WORKER_AUTO_SENTINEL = 0

  encrypts :api_key_ciphertext

  store_accessor :settings_json,
    :compatibility_mode,
    :request_timeout_seconds,
    :retry_max_attempts,
    :supported_for_delete,
    :sonarr_fetch_workers,
    :radarr_moviefile_fetch_workers,
    :tautulli_history_page_size,
    :tautulli_metadata_workers

  has_many :arr_tags, dependent: :destroy
  has_many :deletion_actions, dependent: :restrict_with_exception
  has_many :episodes, dependent: :destroy
  has_many :media_files, dependent: :restrict_with_exception
  has_many :movies, dependent: :destroy
  has_many :path_mappings, dependent: :destroy
  has_many :series, dependent: :destroy

  enum :kind, { sonarr: "sonarr", radarr: "radarr", tautulli: "tautulli" }

  before_validation :normalize_name_and_base_url
  before_validation :apply_setting_defaults

  validates :base_url, :kind, :name, presence: true
  validates :api_key, presence: true, on: :create
  validates :name, uniqueness: true
  validates :verify_ssl, inclusion: { in: [ true, false ] }
  validates :compatibility_mode, inclusion: { in: COMPATIBILITY_MODES }

  validate :validate_base_url_safety

  def request_timeout_seconds
    raw_value = settings_json["request_timeout_seconds"] || 15
    raw_value.to_i.clamp(1, 120)
  end

  def retry_max_attempts
    raw_value = settings_json["retry_max_attempts"] || 5
    raw_value.to_i.clamp(1, 10)
  end

  def sonarr_fetch_workers
    raw_value = settings_json["sonarr_fetch_workers"] || 4
    raw_value.to_i.clamp(WORKER_AUTO_SENTINEL, WORKER_COUNT_MAX)
  end

  def sonarr_fetch_workers_resolved
    resolve_worker_count(sonarr_fetch_workers)
  end

  def radarr_moviefile_fetch_workers
    raw_value = settings_json["radarr_moviefile_fetch_workers"] || 4
    raw_value.to_i.clamp(WORKER_AUTO_SENTINEL, WORKER_COUNT_MAX)
  end

  def radarr_moviefile_fetch_workers_resolved
    resolve_worker_count(radarr_moviefile_fetch_workers)
  end

  def tautulli_history_page_size
    raw_value = settings_json["tautulli_history_page_size"] || 500
    raw_value.to_i.clamp(50, 5_000)
  end

  def tautulli_metadata_workers
    raw_value = settings_json["tautulli_metadata_workers"] || 4
    raw_value.to_i.clamp(WORKER_AUTO_SENTINEL, WORKER_COUNT_MAX)
  end

  def tautulli_metadata_workers_resolved
    resolve_worker_count(tautulli_metadata_workers)
  end

  def api_key
    value = api_key_ciphertext
    return if value.blank?

    value
  rescue ActiveRecord::Encryption::Errors::Decryption
    nil
  end

  def api_key=(value)
    self.api_key_ciphertext = value.presence
  end

  def api_key_present?
    read_attribute_before_type_cast("api_key_ciphertext").present?
  end

  def rotate_api_key_ciphertext!
    plaintext = api_key
    return false if plaintext.blank?

    previous_ciphertext = read_attribute_before_type_cast("api_key_ciphertext")
    self.api_key_ciphertext = plaintext
    api_key_ciphertext_will_change!
    save!(validate: false, touch: false)

    read_attribute_before_type_cast("api_key_ciphertext") != previous_ciphertext
  end

  def supported_for_delete?
    ActiveModel::Type::Boolean.new.cast(settings_json["supported_for_delete"])
  end

  def compatibility_mode
    settings_json["compatibility_mode"].presence || AppSetting.db_value_for("compatibility_mode_default")
  end

  def assign_api_key_if_present(api_key_value)
    return if api_key_value.blank?

    self.api_key = api_key_value
  end

  def as_api_json
    {
      id: id,
      kind: kind,
      name: name,
      base_url: base_url,
      verify_ssl: verify_ssl,
      status: status,
      reported_version: reported_version,
      last_error: last_error,
      last_checked_at: last_checked_at,
      api_key_present: api_key_present?,
      compatibility: {
        mode: compatibility_mode,
        supported_for_delete: supported_for_delete?
      },
      tuning: {
        request_timeout_seconds: request_timeout_seconds,
        retry_max_attempts: retry_max_attempts,
        sonarr_fetch_workers: sonarr_fetch_workers,
        sonarr_fetch_workers_resolved: sonarr_fetch_workers_resolved,
        radarr_moviefile_fetch_workers: radarr_moviefile_fetch_workers,
        radarr_moviefile_fetch_workers_resolved: radarr_moviefile_fetch_workers_resolved,
        tautulli_history_page_size: tautulli_history_page_size,
        tautulli_metadata_workers: tautulli_metadata_workers,
        tautulli_metadata_workers_resolved: tautulli_metadata_workers_resolved
      },
      tautulli_history_state: tautulli_history_state_summary,
      tautulli_library_mapping_state: tautulli_library_mapping_state_summary,
      path_mappings: path_mappings.order(:from_prefix).map do |mapping|
        {
          id: mapping.id,
          from_prefix: mapping.from_prefix,
          to_prefix: mapping.to_prefix,
          enabled: mapping.enabled
        }
      end
    }
  end

  private

  def tautulli_history_state_summary
    return nil unless tautulli?

    state = settings_json["history_sync_state"] || {}
    {
      present: state.present?,
      watermark_id: state["watermark_id"].to_i,
      max_seen_history_id: state["max_seen_history_id"].to_i,
      recent_ids_count: Array(state["recent_ids"]).size
    }
  end

  def tautulli_library_mapping_state_summary
    return nil unless tautulli?

    state = settings_json["library_mapping_state"] || {}
    libraries = state["libraries"].is_a?(Hash) ? state["libraries"] : {}
    active_cursors_count = libraries.values.count { |entry| entry.is_a?(Hash) && entry["next_start"].to_i.positive? }
    completed_cycles = libraries.values.sum do |entry|
      next 0 unless entry.is_a?(Hash)

      entry["completed_cycle_count"].to_i
    end

    {
      present: state.present?,
      libraries_count: libraries.size,
      active_cursors_count: active_cursors_count,
      completed_cycles: completed_cycles,
      last_run_at: state["last_run_at"]
    }
  end

  def normalize_name_and_base_url
    self.name = name.to_s.strip
    self.base_url = Integrations::BaseUrlSafetyValidator.normalize(base_url)
  end

  def apply_setting_defaults
    self.settings_json = (settings_json || {}).deep_stringify_keys
    settings_json["compatibility_mode"] ||= AppSetting.db_value_for("compatibility_mode_default")
    settings_json["request_timeout_seconds"] = request_timeout_seconds
    settings_json["retry_max_attempts"] = retry_max_attempts
    settings_json["sonarr_fetch_workers"] = sonarr_fetch_workers
    settings_json["radarr_moviefile_fetch_workers"] = radarr_moviefile_fetch_workers
    settings_json["tautulli_history_page_size"] = tautulli_history_page_size
    settings_json["tautulli_metadata_workers"] = tautulli_metadata_workers
    self.verify_ssl = true if verify_ssl.nil?
  end

  def resolve_worker_count(configured_value)
    return configured_value if configured_value.positive?

    auto_worker_count
  end

  def auto_worker_count
    processors = Integer(Etc.nprocessors, exception: false)
    processors = 2 if processors.nil? || processors <= 0

    [ processors - 1, 1 ].max.clamp(1, WORKER_COUNT_MAX)
  rescue StandardError
    1
  end

  def validate_base_url_safety
    Integrations::BaseUrlSafetyValidator.validate!(base_url)
  rescue Integrations::UnsafeBaseUrlError => e
    errors.add(:base_url, e.message)
  end
end
