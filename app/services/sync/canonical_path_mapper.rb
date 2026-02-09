module Sync
  class CanonicalPathMapper
    def initialize(integration:)
      @mappings = integration.path_mappings.where(enabled: true).order(Arel.sql("LENGTH(from_prefix) DESC"))
    end

    def canonicalize(path)
      normalized = Paths::Normalizer.normalize(path)
      mapping = mappings.find { |candidate| prefix_match?(normalized, candidate.from_prefix) }
      return normalized if mapping.blank?

      suffix = normalized.delete_prefix(mapping.from_prefix)
      translated = join_canonical_path(mapping.to_prefix, suffix)
      Paths::Normalizer.normalize(translated)
    end

    private

    attr_reader :mappings

    def prefix_match?(path, prefix)
      return path.start_with?("/") if prefix == "/"

      path == prefix || path.start_with?("#{prefix}/")
    end

    def join_canonical_path(to_prefix, suffix)
      normalized_suffix = suffix.to_s
      return to_prefix if normalized_suffix.blank?

      if to_prefix == "/"
        "/#{normalized_suffix.delete_prefix('/')}"
      elsif normalized_suffix.start_with?("/")
        "#{to_prefix}#{normalized_suffix}"
      else
        "#{to_prefix}/#{normalized_suffix}"
      end
    end
  end
end
