module Paths
  class ManagedRootClassifier
    def initialize(managed_path_roots:)
      @managed_path_roots = Array(managed_path_roots)
    end

    def classify(path)
      normalized_path = Paths::Normalizer.normalize(path)
      matched_root = Paths::PrefixMatcher.best_match(path: normalized_path, candidates: managed_path_roots)

      {
        normalized_path: normalized_path,
        ownership: matched_root.present? ? "managed" : "external",
        matched_managed_root: matched_root
      }
    end

    private

    attr_reader :managed_path_roots
  end
end
