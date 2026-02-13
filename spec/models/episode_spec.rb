require "rails_helper"

RSpec.describe Episode, type: :model do
  def create_integration!
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Episode Model",
      base_url: "https://sonarr.episode-model.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  def create_season!(integration:)
    series = Series.create!(
      integration: integration,
      sonarr_series_id: 77_001,
      title: "Episode Model Series"
    )
    Season.create!(series: series, season_number: 1)
  end

  def create_episode!(integration:, sonarr_episode_id:, episode_number:, attrs: {})
    described_class.create!(
      {
        integration: integration,
        season: create_season!(integration: integration),
        sonarr_episode_id: sonarr_episode_id,
        episode_number: episode_number
      }.merge(attrs)
    )
  end

  it "defaults mapping columns to unresolved state" do
    integration = create_integration!
    episode = create_episode!(integration: integration, sonarr_episode_id: 9011, episode_number: 1)

    expect(episode.mapping_status_code).to eq("unresolved")
    expect(episode.mapping_strategy).to eq("no_match")
    expect(episode.mapping_diagnostics_json).to eq({})
    expect(episode.mapping_status_changed_at).to be_nil
  end

  it "validates mapping status code inclusion" do
    integration = create_integration!
    episode = described_class.new(
      integration: integration,
      season: create_season!(integration: integration),
      sonarr_episode_id: 9012,
      episode_number: 1,
      mapping_status_code: "invalid_status"
    )

    expect(episode).not_to be_valid
    expect(episode.errors[:mapping_status_code]).to include("is not included in the list")
  end
end
