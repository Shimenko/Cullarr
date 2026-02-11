require "net/http"
require "uri"

module Images
  class ProxyFetch
    REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze
    MAX_REDIRECTS = 3

    Result = Struct.new(:body, :content_type, :source_url, keyword_init: true)

    class ProxyError < StandardError
      attr_reader :code, :details, :status

      def initialize(code:, message:, status:, details: {})
        @code = code
        @status = status
        @details = details
        super(message)
      end
    end

    class DefaultRequester
      def get(uri:, timeout_seconds:)
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: timeout_seconds,
          read_timeout: timeout_seconds
        ) do |http|
          request = Net::HTTP::Get.new(uri.request_uri.presence || "/")
          request["User-Agent"] = "CullarrImageProxy/1.0"
          http.request(request)
        end
      end
    end

    def initialize(url:, allowed_host_patterns:, timeout_seconds:, max_bytes:, requester: DefaultRequester.new)
      @url = url.to_s.strip
      @allowed_host_patterns = Array(allowed_host_patterns).map { |host| normalize_host(host) }.reject(&:blank?).uniq
      @timeout_seconds = Integer(timeout_seconds, exception: false).to_i.clamp(1, 120)
      @max_bytes = Integer(max_bytes, exception: false).to_i.clamp(65_536, 52_428_800)
      @requester = requester
    end

    def call
      raise_invalid_url!("Image URL is required.") if url.blank?
      raise_disallowed_host!("Image proxy host allowlist is empty.") if allowed_host_patterns.empty?

      current_uri = parse_http_uri!(url)
      ensure_allowed_host!(current_uri.host, code: "image_proxy_disallowed_host")

      redirects = 0
      loop do
        response = requester.get(uri: current_uri, timeout_seconds: timeout_seconds)
        status = response.code.to_i

        if REDIRECT_STATUSES.include?(status)
          redirects += 1
          raise_redirect_blocked!("Image redirect limit exceeded.") if redirects > MAX_REDIRECTS

          current_uri = resolve_redirect_uri!(current_uri:, response:)
          ensure_allowed_host!(current_uri.host, code: "image_proxy_redirect_blocked")
          next
        end

        return build_result!(response:, source_uri: current_uri) if status.between?(200, 299)

        raise ProxyError.new(
          code: "service_unavailable",
          message: "Image source request failed with HTTP #{status}.",
          status: :service_unavailable
        )
      end
    rescue SocketError, SystemCallError, Timeout::Error, Net::ReadTimeout, Net::OpenTimeout => e
      raise ProxyError.new(
        code: "service_unavailable",
        message: "Image source is unreachable.",
        status: :service_unavailable,
        details: { cause: e.class.name }
      )
    end

    private

    attr_reader :allowed_host_patterns, :max_bytes, :requester, :timeout_seconds, :url

    def build_result!(response:, source_uri:)
      content_type = header(response, "content-type").to_s.split(";").first.to_s.strip
      unless content_type.start_with?("image/")
        raise ProxyError.new(
          code: "validation_failed",
          message: "Image source response is not an image.",
          status: :unprocessable_content
        )
      end

      body = response.body.to_s.b
      if body.bytesize > max_bytes
        raise ProxyError.new(
          code: "validation_failed",
          message: "Image response exceeded max allowed bytes.",
          status: :unprocessable_content,
          details: { max_bytes: max_bytes }
        )
      end

      Result.new(
        body: body,
        content_type: content_type,
        source_url: source_uri.to_s
      )
    end

    def resolve_redirect_uri!(current_uri:, response:)
      location = header(response, "location").to_s
      raise_redirect_blocked!("Image redirect is missing a Location header.") if location.blank?

      URI.parse(URI.join(current_uri.to_s, location).to_s).tap do |redirect_uri|
        unless redirect_uri.is_a?(URI::HTTP) || redirect_uri.is_a?(URI::HTTPS)
          raise_redirect_blocked!("Image redirect target must use HTTP or HTTPS.")
        end

        raise_redirect_blocked!("Image redirect target must include a host.") if redirect_uri.host.blank?
      end
    rescue URI::InvalidURIError
      raise_redirect_blocked!("Image redirect target is invalid.")
    end

    def ensure_allowed_host!(host, code:)
      normalized_host = normalize_host(host)
      return if normalized_host.present? && allowed_host_patterns.any? do |pattern|
        File.fnmatch?(pattern, normalized_host, File::FNM_CASEFOLD)
      end

      if code == "image_proxy_redirect_blocked"
        raise_redirect_blocked!("Image redirect target host is not allowlisted.")
      else
        raise_disallowed_host!("Image source host is not allowlisted.")
      end
    end

    def parse_http_uri!(value)
      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise_invalid_url!("Image URL must use HTTP or HTTPS.")
      end
      raise_invalid_url!("Image URL must include a host.") if uri.host.blank?

      uri
    rescue URI::InvalidURIError
      raise_invalid_url!("Image URL must be a valid URL.")
    end

    def normalize_host(host)
      host.to_s.downcase.strip.delete_suffix(".")
    end

    def header(response, key)
      response[key] || response[key.downcase]
    end

    def raise_invalid_url!(message)
      raise ProxyError.new(code: "validation_failed", message: message, status: :unprocessable_content)
    end

    def raise_disallowed_host!(message)
      raise ProxyError.new(code: "image_proxy_disallowed_host", message: message, status: :unprocessable_content)
    end

    def raise_redirect_blocked!(message)
      raise ProxyError.new(code: "image_proxy_redirect_blocked", message: message, status: :unprocessable_content)
    end
  end
end
