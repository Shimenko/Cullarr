require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Deletion::BuildActionContext, type: :service do
  def create_sonarr_integration!
    Integration.create!(
      kind: "sonarr",
      name: "Sonarr Context Builder",
      base_url: "https://sonarr.context-builder.local",
      api_key: "secret",
      verify_ssl: true,
      settings_json: { "supported_for_delete" => true }
    )
  end

  def create_episode_with_file!(integration:, season:, sonarr_episode_id:, episode_number:, arr_file_id:, path_suffix:)
    episode = Episode.create!(
      integration: integration,
      season: season,
      sonarr_episode_id: sonarr_episode_id,
      episode_number: episode_number,
      title: "Episode #{episode_number}"
    )
    media_file = MediaFile.create!(
      attachable: episode,
      integration: integration,
      arr_file_id: arr_file_id,
      path: "/media/tv/#{path_suffix}.mkv",
      path_canonical: "/media/tv/#{path_suffix}.mkv",
      size_bytes: 1.gigabyte
    )

    [ episode, media_file ]
  end

  it "uses server-provided series totals to avoid full-show escalation on partial selection" do
    integration = create_sonarr_integration!
    series = Series.create!(integration: integration, sonarr_series_id: 9201, title: "Partial Show")
    season = Season.create!(series: series, season_number: 1)
    first_episode, first_file = create_episode_with_file!(
      integration: integration,
      season: season,
      sonarr_episode_id: 9202,
      episode_number: 1,
      arr_file_id: 9203,
      path_suffix: "partial-show-s01e01"
    )
    _second_episode, = create_episode_with_file!(
      integration: integration,
      season: season,
      sonarr_episode_id: 9204,
      episode_number: 2,
      arr_file_id: 9205,
      path_suffix: "partial-show-s01e02"
    )

    result = described_class.new(
      scope: "tv_show",
      selected_files_by_attachable: {
        "episode:#{first_episode.id}" => {
          attachable: first_episode,
          selected_files: [ first_file ],
          all_files: [ first_file ]
        }
      },
      series_total_file_counts_by_series_id: { series.id => 2 }
    ).call

    context = result.action_context.fetch(first_file.id.to_s)
    expect(context.fetch(:should_unmonitor)).to be(false)
    expect(context.fetch(:should_tag)).to be(false)
  end

  it "marks full-show delete when selected files equal authoritative series total" do
    integration = create_sonarr_integration!
    series = Series.create!(integration: integration, sonarr_series_id: 9301, title: "Full Show")
    season = Season.create!(series: series, season_number: 1)
    first_episode, first_file = create_episode_with_file!(
      integration: integration,
      season: season,
      sonarr_episode_id: 9302,
      episode_number: 1,
      arr_file_id: 9303,
      path_suffix: "full-show-s01e01"
    )

    result = described_class.new(
      scope: "tv_show",
      selected_files_by_attachable: {
        "episode:#{first_episode.id}" => {
          attachable: first_episode,
          selected_files: [ first_file ],
          all_files: [ first_file ]
        }
      },
      series_total_file_counts_by_series_id: { series.id => 1 }
    ).call

    context = result.action_context.fetch(first_file.id.to_s)
    expect(context.fetch(:should_unmonitor)).to be(true)
    expect(context.fetch(:should_tag)).to be(true)
    expect(context.fetch(:unmonitor_kind)).to eq("series")
    expect(context.fetch(:tag_kind)).to eq("series")
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
