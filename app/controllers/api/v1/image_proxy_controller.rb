require "uri"

module Api
  module V1
    class ImageProxyController < BaseController
      def show
        result = Images::ProxyFetch.new(
          url: params.require(:url),
          allowed_host_patterns: allowed_host_patterns,
          timeout_seconds: AppSetting.db_value_for("image_proxy_timeout_seconds"),
          max_bytes: AppSetting.db_value_for("image_proxy_max_bytes")
        ).call

        send_data result.body,
                  type: result.content_type,
                  disposition: "inline",
                  filename: "image-proxy"
      rescue ActionController::ParameterMissing
        render_validation_error(fields: { url: [ "is required" ] })
      rescue Images::ProxyFetch::ProxyError => e
        render_api_error(
          code: e.code,
          message: e.message,
          status: e.status,
          details: e.details
        )
      end

      private

      def allowed_host_patterns
        env_patterns = ENV.fetch("CULLARR_IMAGE_PROXY_ALLOWED_HOSTS", "")
                          .split(",")
                          .map(&:strip)
                          .reject(&:blank?)
        return env_patterns if env_patterns.any?

        Integration
          .where(kind: %w[tautulli sonarr radarr])
          .pluck(:base_url)
          .filter_map { |value| URI.parse(value).host&.downcase }
          .uniq
      rescue URI::InvalidURIError
        []
      end
    end
  end
end
