class RunsChannel < ApplicationCable::Channel
  def subscribed
    reject unless current_operator.present?

    stream_from "sync_runs"
    stream_from "deletion_runs"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
