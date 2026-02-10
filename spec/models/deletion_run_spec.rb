require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe DeletionRun, type: :model do
  def create_operator!
    Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  def create_integration!
    Integration.create!(
      kind: "radarr",
      name: "Deletion Summary Radarr",
      base_url: "https://summary.radarr.local",
      api_key: "secret",
      verify_ssl: true
    )
  end

  def create_movie_with_file!(integration:, seed:)
    movie = Movie.create!(
      integration: integration,
      radarr_movie_id: 90_000 + seed,
      title: "Summary Movie #{seed}",
      duration_ms: 100_000
    )

    media_file = MediaFile.create!(
      attachable: movie,
      integration: integration,
      arr_file_id: 95_000 + seed,
      path: "/media/summary-#{seed}.mkv",
      path_canonical: "/media/summary-#{seed}.mkv",
      size_bytes: 1.gigabyte
    )

    [ movie, media_file ]
  end

  it "aggregates action summary counts for each requested run id" do
    operator = create_operator!
    integration = create_integration!
    run_one = described_class.create!(operator: operator, status: "running", scope: "movie")
    run_two = described_class.create!(operator: operator, status: "queued", scope: "movie")

    _movie_one, file_one = create_movie_with_file!(integration: integration, seed: 1)
    _movie_two, file_two = create_movie_with_file!(integration: integration, seed: 2)
    _movie_three, file_three = create_movie_with_file!(integration: integration, seed: 3)
    _movie_four, file_four = create_movie_with_file!(integration: integration, seed: 4)

    DeletionAction.create!(
      deletion_run: run_one,
      media_file: file_one,
      integration: integration,
      idempotency_key: "summary:#{run_one.id}:#{file_one.id}",
      status: "confirmed",
      stage_timestamps_json: {}
    )
    DeletionAction.create!(
      deletion_run: run_one,
      media_file: file_two,
      integration: integration,
      idempotency_key: "summary:#{run_one.id}:#{file_two.id}",
      status: "failed",
      stage_timestamps_json: {}
    )
    DeletionAction.create!(
      deletion_run: run_two,
      media_file: file_three,
      integration: integration,
      idempotency_key: "summary:#{run_two.id}:#{file_three.id}",
      status: "queued",
      stage_timestamps_json: {}
    )
    DeletionAction.create!(
      deletion_run: run_two,
      media_file: file_four,
      integration: integration,
      idempotency_key: "summary:#{run_two.id}:#{file_four.id}",
      status: "confirmed",
      stage_timestamps_json: {}
    )

    summaries = described_class.action_summary_by_run_id([ run_one.id, run_two.id ])

    expect(summaries[run_one.id]).to include(confirmed: 1, failed: 1, queued: 0)
    expect(summaries[run_two.id]).to include(queued: 1, confirmed: 1, failed: 0)
    expect(summaries[run_one.id].keys).to match_array(described_class.default_action_summary.keys)
    expect(summaries[run_two.id].keys).to match_array(described_class.default_action_summary.keys)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
