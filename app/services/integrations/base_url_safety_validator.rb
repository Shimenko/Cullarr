require "ipaddr"
require "resolv"
require "uri"

module Integrations
  class BaseUrlSafetyValidator
    ALLOWED_HOSTS_ENV_KEY = "CULLARR_ALLOWED_INTEGRATION_HOSTS"
    ALLOWED_NETWORK_RANGES_ENV_KEY = "CULLARR_ALLOWED_INTEGRATION_NETWORK_RANGES"

    class << self
      def validate!(base_url, env: ENV)
        uri = URI.parse(base_url.to_s.strip)

        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise Integrations::UnsafeBaseUrlError.new("base_url must use http or https")
        end

        if uri.host.blank?
          raise Integrations::UnsafeBaseUrlError.new("base_url must include a host")
        end

        allowed_hosts = configured_allowed_hosts(env:)
        allowed_networks = configured_allowed_network_ranges(env:)
        return true if allowed_hosts.empty? && allowed_networks.empty?

        return true if host_allowed?(uri.host, allowed_hosts)
        return true if ip_allowed?(uri.host, allowed_networks)
        return true if resolved_to_allowed_ip?(uri.host, allowed_networks)

        raise Integrations::UnsafeBaseUrlError.new(
          "base_url host is not allowed by configured integration network policy"
        )
      rescue URI::InvalidURIError
        raise Integrations::UnsafeBaseUrlError.new("base_url must be a valid URL")
      end

      def normalize(base_url)
        uri = URI.parse(base_url.to_s.strip)
        uri.path = uri.path.sub(%r{/\z}, "")
        uri.path = "/" if uri.path.blank?
        uri.query = nil if uri.query.blank?
        uri.fragment = nil
        uri.to_s.sub(%r{/\z}, "")
      rescue URI::InvalidURIError
        base_url.to_s.strip
      end

      private

      def configured_allowed_hosts(env: ENV)
        csv_setting(env: env, key: ALLOWED_HOSTS_ENV_KEY).map(&:downcase)
      end

      def configured_allowed_network_ranges(env: ENV)
        ranges = csv_setting(env: env, key: ALLOWED_NETWORK_RANGES_ENV_KEY)
        ranges.map { |range| IPAddr.new(range) }
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        raise Integrations::UnsafeBaseUrlError.new(
          "#{ALLOWED_NETWORK_RANGES_ENV_KEY} must contain valid CIDR network ranges"
        )
      end

      def csv_setting(env:, key:)
        env.fetch(key, "").to_s.split(",").map(&:strip).reject(&:blank?)
      end

      def host_allowed?(host, allowed_hosts)
        normalized_host = normalize_host(host)
        allowed_hosts.any? do |pattern|
          File.fnmatch?(pattern, normalized_host, File::FNM_CASEFOLD)
        end
      end

      def ip_allowed?(host, allowed_networks)
        ip = parse_ip(host)
        ip && allowed_network?(ip, allowed_networks)
      end

      def resolved_to_allowed_ip?(host, allowed_networks)
        Resolv.each_address(host).any? do |address|
          ip = parse_ip(address)
          ip && allowed_network?(ip, allowed_networks)
        end
      rescue Resolv::ResolvError
        false
      end

      def parse_ip(value)
        IPAddr.new(value)
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        nil
      end

      def allowed_network?(ip, allowed_networks)
        allowed_networks.any? { |network| network.include?(ip) }
      end

      def normalize_host(host)
        host.to_s.downcase.delete_suffix(".")
      end
    end
  end
end
