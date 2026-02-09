module Integrations
  class HealthCheck
    def initialize(integration, raise_on_unsupported: false)
      @integration = integration
      @raise_on_unsupported = raise_on_unsupported
    end

    def call
      result = adapter.check_health!
      persist_result!(result)
      result.merge(compatibility_mode: integration.compatibility_mode)
    rescue UnsupportedVersionError => error
      result = {
        status: "unsupported",
        reported_version: error.details[:reported_version] || integration.reported_version,
        supported_for_delete: false,
        compatibility_mode: integration.compatibility_mode
      }
      persist_result!(result, last_error: error.message)
      raise if raise_on_unsupported

      result
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError
      integration.update!(
        status: "error",
        last_checked_at: Time.current,
        last_error: "integration unreachable"
      )
      raise ConnectivityError.new("integration unreachable")
    rescue AuthError, ConnectivityError, RateLimitedError, ContractMismatchError => e
      integration.update!(
        status: "error",
        last_checked_at: Time.current,
        last_error: e.message
      )
      raise
    end

    private

    attr_reader :integration

    attr_reader :raise_on_unsupported

    def adapter
      @adapter ||= AdapterFactory.for(integration:)
    end

    def persist_result!(result, last_error: nil)
      integration.update!(
        status: result.fetch(:status),
        reported_version: result[:reported_version],
        last_checked_at: Time.current,
        last_error: last_error,
        settings_json: integration.settings_json.merge("supported_for_delete" => result.fetch(:supported_for_delete))
      )
    end
  end
end
