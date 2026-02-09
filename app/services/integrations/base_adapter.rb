module Integrations
  class BaseAdapter
    def initialize(integration:, connection: nil)
      @integration = integration
      @connection = connection
    end

    private

    attr_reader :integration

    def request_json(method:, path:, params: {}, headers: {}, body: nil)
      attempts = 0

      begin
        attempts += 1
        response = connection.public_send(method, path) do |request|
          request.headers.merge!(headers)
          params.each { |key, value| request.params[key] = value }
          request.body = body if body.present?
        end

        parse_json_response(response)
      rescue Faraday::ConnectionFailed, Faraday::TimeoutError => error
        if attempts < integration.retry_max_attempts
          sleep_with_backoff(attempts)
          retry
        end

        raise ConnectivityError.new("integration unreachable", details: { cause: error.class.name })
      rescue RateLimitedError => error
        if attempts < integration.retry_max_attempts
          sleep_with_backoff(attempts, minimum_sleep_seconds: error.details[:retry_after].to_i)
          retry
        end

        raise error
      end
    end

    def parse_json_response(response)
      case response.status
      when 200..299
        return {} if response.body.blank?

        JSON.parse(response.body)
      when 401, 403
        raise AuthError.new("integration authentication failed")
      when 429
        raise RateLimitedError.new(
          "integration is rate-limited",
          details: { retry_after: response.headers["Retry-After"] }
        )
      when 500..599
        raise ConnectivityError.new("integration service unavailable")
      else
        raise ConnectivityError.new("integration returned unexpected status #{response.status}")
      end
    rescue JSON::ParserError, TypeError
      raise ContractMismatchError.new("integration returned malformed JSON")
    end

    def ensure_present!(hash, key)
      value = hash[key.to_s]
      return value if value.present? || value == false

      raise ContractMismatchError.new(
        "integration response did not include required fields",
        details: { missing_key: key.to_s }
      )
    end

    def check_compatibility!(reported_version)
      supported = CompatibilityPolicy.supports?(kind: integration.kind, version: reported_version)
      compatibility_mode = integration.compatibility_mode

      if supported
        return {
          status: "healthy",
          reported_version: reported_version,
          supported_for_delete: true,
          warnings: []
        }
      end

      if compatibility_mode == "warn_only_read_only"
        return {
          status: "warning",
          reported_version: reported_version,
          supported_for_delete: false,
          warnings: [ "unsupported version running in warn-only read mode" ]
        }
      end

      raise UnsupportedVersionError.new(
        "integration version is unsupported",
        details: {
          integration_kind: integration.kind,
          reported_version: reported_version
        }
      )
    end

    def connection
      @connection ||= Faraday.new(url: integration.base_url, ssl: { verify: integration.verify_ssl }) do |builder|
        builder.options.timeout = integration.request_timeout_seconds
        builder.options.open_timeout = integration.request_timeout_seconds
      end
    end

    def sleep_with_backoff(attempts, minimum_sleep_seconds: 0)
      base_sleep = 0.15 * (2**(attempts - 1))
      jitter = rand * 0.05
      sleep_seconds = [ base_sleep + jitter, minimum_sleep_seconds.to_f ].max
      sleep(sleep_seconds) unless Rails.env.test?
    end
  end
end
