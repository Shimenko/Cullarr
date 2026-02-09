class PathMappingsController < ApplicationController
  before_action :set_integration
  before_action :set_path_mapping, only: %i[update destroy]

  def create
    mapping = @integration.path_mappings.create!(path_mapping_params)
    record_event(mapping, "path_mapping_created")
    redirect_to settings_path, notice: "Path mapping created."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def update
    @path_mapping.update!(path_mapping_params)
    record_event(@path_mapping, "path_mapping_updated")
    redirect_to settings_path, notice: "Path mapping updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    @path_mapping.destroy!
    record_event(@path_mapping, "path_mapping_deleted")
    redirect_to settings_path, notice: "Path mapping deleted."
  end

  private

  def set_integration
    @integration = Integration.find(params[:integration_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to settings_path, alert: "Integration not found."
  end

  def set_path_mapping
    @path_mapping = @integration.path_mappings.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to settings_path, alert: "Path mapping not found."
  end

  def path_mapping_params
    params.require(:path_mapping).permit(:from_prefix, :to_prefix, :enabled)
  end

  def record_event(mapping, action)
    AuditEvents::Recorder.record!(
      event_name: "cullarr.integration.updated",
      correlation_id: request.request_id,
      actor: current_operator,
      subject: mapping,
      payload: { action: action }
    )
  end
end
