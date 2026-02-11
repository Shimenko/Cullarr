class Retention::PruneJob < ApplicationJob
  queue_as :default

  def perform
    Retention::Prune.new.call
  end
end
