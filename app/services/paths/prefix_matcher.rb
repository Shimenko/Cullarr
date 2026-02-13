module Paths
  class PrefixMatcher
    class << self
      def best_match(path:, candidates:, &prefix_block)
        normalized_path = path.to_s
        best_candidate = nil
        best_length = -1

        candidates.each do |candidate|
          prefix = (prefix_block ? prefix_block.call(candidate) : candidate).to_s
          next unless boundary_match?(path: normalized_path, prefix:)

          prefix_length = prefix.length
          next if prefix_length < best_length

          if prefix_length > best_length
            best_candidate = candidate
            best_length = prefix_length
          end
        end

        best_candidate
      end

      def boundary_match?(path:, prefix:)
        return false if prefix.blank?
        return path.start_with?("/") if prefix == "/"

        path == prefix || path.start_with?("#{prefix}/")
      end
    end
  end
end
