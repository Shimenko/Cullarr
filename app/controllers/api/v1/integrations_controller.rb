module Api
  module V1
    class IntegrationsController < BaseController
      before_action :set_integration, only: %i[update destroy check reset_history_state]
      before_action :require_recent_reauthentication!, only: %i[create update destroy reset_history_state]

      def index
        render json: { integrations: Integration.order(:name).map(&:as_api_json) }
      end

      def create
        integration = Integration.new(create_update_attributes)
        integration.assign_api_key_if_present(integration_params[:api_key])
        integration.save!
        record_integration_event("cullarr.integration.created", integration)

        render json: { integration: integration.as_api_json }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def update
        @integration.assign_attributes(create_update_attributes)
        @integration.assign_api_key_if_present(integration_params[:api_key])
        @integration.save!
        record_integration_event("cullarr.integration.updated", @integration)

        render json: { integration: @integration.as_api_json }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(fields: e.record.errors.to_hash(true))
      end

      def destroy
        @integration.destroy!
        record_integration_event("cullarr.integration.updated", @integration, action: "destroyed")
        render json: { ok: true }
      rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::DeleteRestrictionError
        render_api_error(
          code: "conflict",
          message: "Integration cannot be deleted while dependent records exist.",
          status: :conflict
        )
      end

      def check
        result = Integrations::HealthCheck.new(@integration).call
        record_check_event(result)

        render json: { integration: @integration.reload.as_api_json }
      rescue Integrations::AuthError => e
        render_api_error(code: "integration_auth_failed", message: e.message, status: :unauthorized)
      rescue Integrations::ConnectivityError => e
        render_api_error(code: "integration_unreachable", message: e.message, status: :service_unavailable)
      rescue Integrations::RateLimitedError => e
        render_api_error(code: "rate_limited", message: e.message, status: :too_many_requests)
      rescue Integrations::ContractMismatchError => e
        render_api_error(code: "integration_contract_mismatch", message: e.message, status: :bad_gateway)
      end

      def reset_history_state
        unless @integration.tautulli?
          return render_validation_error(fields: { integration: [ "history state reset is only available for tautulli integrations" ] })
        end

        prior_state = @integration.settings_json["history_sync_state"]
        if prior_state.blank?
          return render json: { integration: @integration.as_api_json, reset: false, reason: "already_clear" }
        end

        settings = @integration.settings_json.deep_dup
        settings.delete("history_sync_state")
        @integration.update!(settings_json: settings)
        record_integration_event("cullarr.integration.updated", @integration, action: "history_state_reset")

        render json: { integration: @integration.as_api_json, reset: true }
      end

      private

      def set_integration
        @integration = Integration.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_api_error(code: "not_found", message: "Integration not found.", status: :not_found)
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
          settings_json: integration_settings
        }.compact
        attributes[:verify_ssl] = integration_params[:verify_ssl] unless integration_params[:verify_ssl].nil?
        attributes
      end

      def integration_settings
        (integration_params[:settings] || {}).to_h.compact
      end

      def record_integration_event(event_name, integration, action: nil)
        payload = { kind: integration.kind, status: integration.status }
        payload[:action] = action if action.present?
        AuditEvents::Recorder.record!(
          event_name: event_name,
          correlation_id: request.request_id,
          actor: current_operator,
          subject: integration,
          payload: payload
        )
      end

      def record_check_event(result)
        if result[:status] == "warning"
          event_name = "cullarr.integration.compatibility_warning"
        elsif result[:status] == "unsupported"
          event_name = "cullarr.integration.compatibility_blocked"
        else
          event_name = "cullarr.integration.health_checked"
        end

        AuditEvents::Recorder.record!(
          event_name: event_name,
          correlation_id: request.request_id,
          actor: current_operator,
          subject: @integration,
          payload: {
            status: result[:status],
            reported_version: result[:reported_version],
            supported_for_delete: result[:supported_for_delete],
            compatibility_mode: result[:compatibility_mode]
          }
        )
      end
    end
  end
end
