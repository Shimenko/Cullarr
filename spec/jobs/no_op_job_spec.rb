require "rails_helper"

RSpec.describe NoOpJob, type: :job do
  it "executes successfully" do
    expect(described_class.perform_now).to be(true)
  end
end
