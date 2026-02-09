module Integrations
  class HealthCheck
    def initialize(integration)
      @integration = integration
    end

    def call
      reported_version = fetch_reported_version
      supported = CompatibilityPolicy.supports?(kind: integration.kind, version: reported_version)
      compatibility_mode = integration.compatibility_mode

      status = if supported
        "healthy"
      elsif compatibility_mode == "warn_only_read_only"
        "warning"
      else
        "unsupported"
      end

      integration.update!(
        status: status,
        reported_version: reported_version,
        last_checked_at: Time.current,
        last_error: nil,
        settings_json: integration.settings_json.merge("supported_for_delete" => (supported && status == "healthy"))
      )

      {
        status: status,
        reported_version: reported_version,
        supported_for_delete: supported && status == "healthy",
        compatibility_mode: compatibility_mode
      }
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

    def fetch_reported_version
      case integration.kind
      when "sonarr", "radarr"
        fetch_arr_version
      when "tautulli"
        fetch_tautulli_version
      else
        raise ContractMismatchError.new("unsupported integration kind", details: { kind: integration.kind })
      end
    end

    def fetch_arr_version
      response = connection.get("api/v3/system/status") do |request|
        request.headers["X-Api-Key"] = integration.api_key
      end
      parsed = parse_json_response(response)
      parsed.fetch("version")
    end

    def fetch_tautulli_version
      response = connection.get("api/v2") do |request|
        request.params["apikey"] = integration.api_key
        request.params["cmd"] = "get_tautulli_info"
      end
      parsed = parse_json_response(response)
      parsed.fetch("response").fetch("data").fetch("tautulli_version")
    end

    def parse_json_response(response)
      case response.status
      when 200
        JSON.parse(response.body)
      when 401, 403
        raise AuthError.new("integration authentication failed")
      when 429
        raise RateLimitedError.new("integration is rate-limited")
      else
        raise ConnectivityError.new("integration returned unexpected status #{response.status}")
      end
    rescue JSON::ParserError
      raise ContractMismatchError.new("integration returned malformed JSON")
    rescue KeyError
      raise ContractMismatchError.new("integration response did not include required fields")
    end

    def connection
      @connection ||= Faraday.new(url: integration.base_url, ssl: { verify: integration.verify_ssl }) do |builder|
        builder.options.timeout = integration.request_timeout_seconds
        builder.options.open_timeout = integration.request_timeout_seconds
      end
    end
  end
end
