class PathExclusionsController < ApplicationController
  before_action :set_path_exclusion, only: %i[update destroy]

  def create
    exclusion = PathExclusion.create!(path_exclusion_params)
    record_event(exclusion, "created")
    redirect_to settings_path, notice: "Path exclusion created."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def update
    @path_exclusion.update!(path_exclusion_params)
    record_event(@path_exclusion, "updated")
    redirect_to settings_path, notice: "Path exclusion updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    @path_exclusion.destroy!
    record_event(@path_exclusion, "deleted")
    redirect_to settings_path, notice: "Path exclusion deleted."
  end

  private

  def set_path_exclusion
    @path_exclusion = PathExclusion.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to settings_path, alert: "Path exclusion not found."
  end

  def path_exclusion_params
    params.require(:path_exclusion).permit(:name, :path_prefix, :enabled)
  end

  def record_event(exclusion, action)
    AuditEvents::Recorder.record!(
      event_name: "cullarr.settings.updated",
      correlation_id: request.request_id,
      actor: current_operator,
      subject: exclusion,
      payload: { action: "path_exclusion_#{action}" }
    )
  end
end
