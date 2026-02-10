module Deletion
  class ValidateDeleteModeUnlock
    Result = Struct.new(:unlock, :error_code, :error_message, keyword_init: true) do
      def success?
        error_code.nil?
      end
    end

    def initialize(token:, operator:, correlation_id:, env: ENV)
      @token = token.to_s
      @operator = operator
      @correlation_id = correlation_id
      @env = env
    end

    def call
      return denied("delete_mode_disabled", "Delete mode is disabled.", reason: "disabled") unless delete_mode_enabled?
      return denied("delete_mode_disabled", "Delete mode is not configured.", reason: "secret_missing") if delete_mode_secret.blank?
      return denied("delete_unlock_required", "Delete unlock is required.", reason: "missing_token") if token.blank?

      unlock = DeleteModeUnlock.find_by_token(token:, secret: delete_mode_secret)
      return denied("delete_unlock_invalid", "Delete unlock token is invalid.", reason: "invalid_token") if unlock.nil?
      return denied("delete_unlock_invalid", "Delete unlock token is invalid.", reason: "wrong_operator") if unlock.operator_id != operator.id
      return denied("delete_unlock_expired", "Delete unlock token has expired.", reason: "expired_token") unless unlock.active?

      Result.new(unlock: unlock)
    end

    private

    attr_reader :correlation_id, :env, :operator, :token

    def delete_mode_enabled?
      ActiveModel::Type::Boolean.new.cast(env["CULLARR_DELETE_MODE_ENABLED"])
    end

    def delete_mode_secret
      env["CULLARR_DELETE_MODE_SECRET"].to_s
    end

    def denied(code, message, reason:)
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.security.delete_unlock_denied",
        correlation_id: correlation_id,
        actor: operator,
        subject_type: "DeleteModeUnlock",
        payload: { reason: reason }
      )

      Result.new(error_code: code, error_message: message)
    end
  end
end
