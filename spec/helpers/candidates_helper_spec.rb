require "rails_helper"

# rubocop:disable RSpec/ExampleLength
RSpec.describe CandidatesHelper, type: :helper do
  describe "#candidate_mapping_status_next_action" do
    it "returns deterministic actions for every v2 mapping status code" do
      expected_actions = {
        "verified_path" => "No action needed.",
        "verified_external_ids" => "Spot-check IDs if this match looks unexpected.",
        "verified_tv_structure" => "Spot-check show/season/episode linkage.",
        "provisional_title_year" => "Run sync recheck and verify IDs before deletion.",
        "external_source_not_managed" => "Review managed path roots and path mappings if this should be ARR-owned.",
        "unresolved" => "Check path mappings and external IDs, then rerun sync.",
        "ambiguous_conflict" => "Resolve source conflict before deletion."
      }

      expected_actions.each do |code, expected_action|
        expect(helper.candidate_mapping_status_next_action(code)).to eq(expected_action)
      end
    end

    it "uses fallback copy for unknown mapping statuses" do
      expect(helper.candidate_mapping_status_next_action("unknown_status_code")).to eq(
        "Inspect mapping diagnostics before proceeding."
      )
    end
  end
end
# rubocop:enable RSpec/ExampleLength
