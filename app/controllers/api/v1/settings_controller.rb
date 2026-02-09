module Api
  module V1
    class SettingsController < BaseController
      before_action :ensure_reauthentication_for_destructive_retention, only: :update

      def show
        render json: { settings: AppSetting.effective_settings }
      end

      def update
        changed_values = AppSetting.apply_updates!(
          settings: params.require(:settings).to_unsafe_h,
          destructive_confirmations: params[:destructive_confirmations]&.to_unsafe_h
        )

        record_update_events(changed_values)
        render json: { ok: true }
      rescue ActionController::ParameterMissing
        render_validation_error(fields: { settings: [ "is required" ] })
      rescue AppSetting::ImmutableSettingError => e
        render_api_error(
          code: "settings_immutable",
          message: "One or more settings are immutable and env-managed.",
          status: :unprocessable_content,
          details: { keys: e.keys }
        )
      rescue AppSetting::UnsafeSettingError => e
        render_api_error(
          code: "retention_setting_unsafe",
          message: "Unsafe retention settings require explicit confirmation.",
          status: :unprocessable_content,
          details: e.details
        )
      rescue AppSetting::InvalidSettingError => e
        render_validation_error(fields: e.details.fetch(:fields, {}))
      end

      private

      def render_validation_error(fields:)
        AuditEvents::Recorder.record_without_subject!(
          event_name: "cullarr.settings.validation_failed",
          correlation_id: request.request_id,
          actor: current_operator,
          subject_type: "AppSetting",
          payload: { fields: fields }
        )
        super
      end

      def record_update_events(changed_values)
        return if changed_values.empty?

        AuditEvents::Recorder.record_without_subject!(
          event_name: "cullarr.settings.updated",
          correlation_id: request.request_id,
          actor: current_operator,
          subject_type: "AppSetting",
          payload: { changed_settings: changed_values }
        )

        return unless changed_values.dig("retention_audit_events_days", :new) == 0

        AuditEvents::Recorder.record_without_subject!(
          event_name: "cullarr.settings.retention_destructive_confirmed",
          correlation_id: request.request_id,
          actor: current_operator,
          subject_type: "AppSetting",
          payload: { key: "retention_audit_events_days", value: 0 }
        )
      end

      def ensure_reauthentication_for_destructive_retention
        retention_target_zero = params.dig(:settings, :retention_audit_events_days).to_s == "0"
        retention_was_non_zero = AppSetting.db_value_for("retention_audit_events_days").to_i != 0
        return unless retention_target_zero && retention_was_non_zero

        require_recent_reauthentication!
      end
    end
  end
end
