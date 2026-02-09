module Paths
  class Normalizer
    class << self
      def normalize(path)
        value = path.to_s.strip
        return "" if value.blank?

        normalized = value.tr("\\", "/")
        normalized = normalized.gsub(%r{/+}, "/")
        normalized = normalized.sub(%r{/\z}, "")
        normalized.presence || "/"
      end
    end
  end
end
