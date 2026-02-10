require "rails_helper"

RSpec.describe RunsChannel, type: :channel do
  it "subscribes to sync and deletion streams for authenticated operators" do
    operator = Operator.create!(
      email: "owner@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
    stub_connection(current_operator: operator)

    subscribe

    expect(subscription).to be_confirmed
    expect(subscription.send(:streams)).to include("sync_runs", "deletion_runs")
  end

  it "rejects unauthenticated subscription attempts" do
    stub_connection(current_operator: nil)

    subscribe

    expect(subscription).to be_rejected
  end
end
