module Integrations
  class CompatibilityPolicy
    SUPPORTED_MIN_VERSIONS = {
      "sonarr" => Gem::Version.new("4.0.0"),
      "radarr" => Gem::Version.new("6.0.0"),
      "tautulli" => Gem::Version.new("2.13.0")
    }.freeze

    class << self
      def supports?(kind:, version:)
        minimum = SUPPORTED_MIN_VERSIONS.fetch(kind.to_s, nil)
        return false if minimum.nil?
        return false if version.blank?

        Gem::Version.new(version) >= minimum
      rescue ArgumentError
        false
      end
    end
  end
end
