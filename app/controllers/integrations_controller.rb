class IntegrationsController < ApplicationController
  before_action :set_integration, only: %i[update destroy check reset_history_state]
  before_action :require_recent_reauthentication_for_mutation!, only: %i[create update destroy reset_history_state]

  def create
    integration = Integration.new(create_update_attributes)
    integration.assign_api_key_if_present(integration_params[:api_key])
    integration.save!

    AuditEvents::Recorder.record!(
      event_name: "cullarr.integration.created",
      correlation_id: request.request_id,
      actor: current_operator,
      subject: integration,
      payload: { kind: integration.kind }
    )

    redirect_to settings_path, notice: "Integration created."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def update
    @integration.assign_attributes(create_update_attributes)
    @integration.assign_api_key_if_present(integration_params[:api_key])
    @integration.save!

    AuditEvents::Recorder.record!(
      event_name: "cullarr.integration.updated",
      correlation_id: request.request_id,
      actor: current_operator,
      subject: @integration,
      payload: { action: "updated" }
    )

    redirect_to settings_path, notice: "Integration updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    @integration.destroy!
    AuditEvents::Recorder.record!(
      event_name: "cullarr.integration.updated",
      correlation_id: request.request_id,
      actor: current_operator,
      subject: @integration,
      payload: { action: "destroyed" }
    )

    redirect_to settings_path, notice: "Integration deleted."
  rescue ActiveRecord::DeleteRestrictionError
    redirect_to settings_path, alert: "Integration has dependent data and cannot be deleted."
  end

  def check
    result = Integrations::HealthCheck.new(@integration).call
    event_name = case result[:status]
    when "healthy"
      "cullarr.integration.health_checked"
    when "warning"
      "cullarr.integration.compatibility_warning"
    when "unsupported"
      "cullarr.integration.compatibility_blocked"
    else
      "cullarr.integration.health_checked"
    end
    AuditEvents::Recorder.record!(
      event_name: event_name,
      correlation_id: request.request_id,
      actor: current_operator,
      subject: @integration,
      payload: result
    )

    redirect_to settings_path, notice: "Integration check completed: #{result[:status]}."
  rescue Integrations::Error => e
    redirect_to settings_path, alert: "Integration check failed: #{e.message}"
  end

  def reset_history_state
    unless @integration.tautulli?
      redirect_to settings_path, alert: "History state reset is only available for Tautulli integrations."
      return
    end

    prior_history_state = @integration.settings_json["history_sync_state"]
    prior_library_mapping_state = @integration.settings_json["library_mapping_state"]
    prior_library_mapping_bootstrap_completed_at = @integration.settings_json["library_mapping_bootstrap_completed_at"]
    if prior_history_state.blank? && prior_library_mapping_state.blank? && prior_library_mapping_bootstrap_completed_at.blank?
      redirect_to settings_path, notice: "History sync state is already clear."
      return
    end

    settings = @integration.settings_json.deep_dup
    settings.delete("history_sync_state")
    settings.delete("library_mapping_state")
    settings.delete("library_mapping_bootstrap_completed_at")
    @integration.update!(settings_json: settings)

    AuditEvents::Recorder.record!(
      event_name: "cullarr.integration.updated",
      correlation_id: request.request_id,
      actor: current_operator,
      subject: @integration,
      payload: {
        action: "history_state_reset",
        prior_history_state: prior_history_state,
        prior_library_mapping_state: prior_library_mapping_state,
        prior_library_mapping_bootstrap_completed_at: prior_library_mapping_bootstrap_completed_at
      }
    )

    redirect_to settings_path, notice: "Tautulli history sync state has been reset."
  end

  private

  def set_integration
    @integration = Integration.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to settings_path, alert: "Integration not found."
  end

  def integration_params
      params.require(:integration).permit(
        :kind,
        :name,
        :base_url,
        :api_key,
        :verify_ssl,
        settings: %i[
          compatibility_mode
          request_timeout_seconds
          retry_max_attempts
          sonarr_fetch_workers
          radarr_moviefile_fetch_workers
          tautulli_history_page_size
          tautulli_metadata_workers
        ]
      )
    end

  def create_update_attributes
    attributes = {
      kind: integration_params[:kind],
      name: integration_params[:name],
      base_url: integration_params[:base_url],
      settings_json: (integration_params[:settings] || {}).to_h
    }.compact
    attributes[:verify_ssl] = integration_params[:verify_ssl] unless integration_params[:verify_ssl].nil?
    attributes
  end

  def require_recent_reauthentication_for_mutation!
    return if reauthenticated_recently?

    redirect_to settings_path, alert: "Re-authenticate before changing integrations."
  end
end
