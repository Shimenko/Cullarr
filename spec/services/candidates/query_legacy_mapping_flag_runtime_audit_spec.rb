require "rails_helper"

RSpec.describe Candidates::Query, type: :service do
  let(:decision_files) do
    [
      "app/services/candidates/query.rb",
      "app/services/deletion/guardrail_evaluator.rb",
      "app/services/sync/tautulli_library_mapping_sync.rb"
    ]
  end

  let(:legacy_flag_decision_patterns) do
    [
      /flag_enabled\(\s*[^,\n]+metadata_json,\s*["'](?:external_id_mismatch|low_confidence_mapping|ambiguous_mapping)["']\s*\)/,
      /metadata_json\[(["'])(?:external_id_mismatch|low_confidence_mapping|ambiguous_mapping)\1\]/,
      /metadata_json\.dig\(\s*(["'])(?:external_id_mismatch|low_confidence_mapping|ambiguous_mapping)\1\s*\)/
    ]
  end

  it "does not use legacy mapping booleans in runtime decision paths" do
    decision_files.each do |relative_path|
      content = Rails.root.join(relative_path).read

      legacy_flag_decision_patterns.each do |pattern|
        expect(content).not_to match(pattern), "#{relative_path} still matches #{pattern.inspect}"
      end
    end
  end
end
