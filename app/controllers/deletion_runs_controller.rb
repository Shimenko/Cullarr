class DeletionRunsController < ApplicationController
  def show
    @deletion_run = DeletionRun.includes(deletion_actions: :media_file).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to runs_path, alert: "Deletion run not found."
  end
end
