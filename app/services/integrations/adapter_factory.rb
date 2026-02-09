module Integrations
  class AdapterFactory
    class << self
      def for(integration:, connection: nil)
        case integration.kind
        when "sonarr"
          SonarrAdapter.new(integration:, connection:)
        when "radarr"
          RadarrAdapter.new(integration:, connection:)
        when "tautulli"
          TautulliAdapter.new(integration:, connection:)
        else
          raise ContractMismatchError.new("unsupported integration kind", details: { kind: integration.kind })
        end
      end
    end
  end
end
