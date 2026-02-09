class SettingsController < ApplicationController
  def show
    @effective_settings = AppSetting.effective_settings
    @integrations = Integration.includes(:path_mappings).order(:name)
    @path_exclusions = PathExclusion.order(:path_prefix)
    @mapping_health_metrics = Sync::MappingHealthMetrics.new.call
  end

  def update
    retention_target_zero = params.dig(:settings, :retention_audit_events_days).to_s == "0"
    retention_was_non_zero = AppSetting.db_value_for("retention_audit_events_days").to_i != 0
    if retention_target_zero && retention_was_non_zero && !reauthenticated_recently?
      return redirect_to settings_path, alert: "Re-authenticate before destructive retention changes."
    end

    changed_values = AppSetting.apply_updates!(
      settings: params.require(:settings).to_unsafe_h,
      destructive_confirmations: params[:destructive_confirmations]&.to_unsafe_h
    )

    if changed_values.any?
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.settings.updated",
        correlation_id: request.request_id,
        actor: current_operator,
        subject_type: "AppSetting",
        payload: { changed_settings: changed_values }
      )
    end

    redirect_to settings_path, notice: "Settings updated."
  rescue ActionController::ParameterMissing
    redirect_to settings_path, alert: "Settings payload is required."
  rescue AppSetting::ImmutableSettingError
    redirect_to settings_path, alert: "Env-managed settings cannot be changed in UI."
  rescue AppSetting::UnsafeSettingError
    redirect_to settings_path, alert: "Destructive retention settings require re-authentication."
  rescue AppSetting::InvalidSettingError => e
    redirect_to settings_path, alert: e.details.dig(:fields)&.values&.flatten&.first || "Settings are invalid."
  end
end
