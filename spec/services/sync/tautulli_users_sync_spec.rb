require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/ReceiveMessages
RSpec.describe Sync::TautulliUsersSync, type: :service do
  let(:sync_run) { SyncRun.create!(status: "running", trigger: "manual") }

  it "upserts tautulli users for each enabled integration" do
    integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Users",
      base_url: "https://tautulli.users.local",
      api_key: "secret",
      verify_ssl: true
    )
    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_users).and_return(
      [
        { tautulli_user_id: 10, friendly_name: "Alice", is_hidden: false },
        { tautulli_user_id: 11, friendly_name: "Bob", is_hidden: true }
      ]
    )

    result = described_class.new(sync_run:, correlation_id: "corr-users").call

    expect(result).to include(integrations: 1, users_fetched: 2, users_upserted: 2)
    expect(PlexUser.find_by!(tautulli_user_id: 10).friendly_name).to eq("Alice")
    expect(PlexUser.find_by!(tautulli_user_id: 11).is_hidden).to be(true)
  end

  it "is idempotent by tautulli_user_id and updates changed fields" do
    integration = Integration.create!(
      kind: "tautulli",
      name: "Tautulli Idempotent",
      base_url: "https://tautulli.idempotent.local",
      api_key: "secret",
      verify_ssl: true
    )
    health_check = instance_double(Integrations::HealthCheck, call: { status: "healthy" })
    allow(Integrations::HealthCheck).to receive(:new).with(integration, raise_on_unsupported: true).and_return(health_check)

    adapter = instance_double(Integrations::TautulliAdapter)
    allow(Integrations::TautulliAdapter).to receive(:new).with(integration:).and_return(adapter)
    allow(adapter).to receive(:fetch_users).and_return(
      [ { tautulli_user_id: 12, friendly_name: "Carla", is_hidden: false } ],
      [ { tautulli_user_id: 12, friendly_name: "Carla Updated", is_hidden: true } ]
    )

    described_class.new(sync_run:, correlation_id: "corr-users-first").call
    described_class.new(sync_run:, correlation_id: "corr-users-second").call

    expect(PlexUser.where(tautulli_user_id: 12).count).to eq(1)
    expect(PlexUser.find_by!(tautulli_user_id: 12).friendly_name).to eq("Carla Updated")
    expect(PlexUser.find_by!(tautulli_user_id: 12).is_hidden).to be(true)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/ReceiveMessages
