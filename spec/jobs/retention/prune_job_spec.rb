require "rails_helper"

RSpec.describe Retention::PruneJob, type: :job do
  it "invokes retention pruning service" do
    prune_service = instance_double(Retention::Prune, call: true)
    allow(Retention::Prune).to receive(:new).and_return(prune_service)

    described_class.perform_now

    expect(Retention::Prune).to have_received(:new)
  end
end
