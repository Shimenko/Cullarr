class NoOpJob < ApplicationJob
  queue_as :default

  def perform(*_args)
    true
  end
end
