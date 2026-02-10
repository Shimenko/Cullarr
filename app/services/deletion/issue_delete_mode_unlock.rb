module Deletion
  class IssueDeleteModeUnlock
    Result = Struct.new(:token, :expires_at, :error_code, :error_message, keyword_init: true) do
      def success?
        error_code.nil?
      end
    end

    def initialize(operator:, password:, correlation_id:, env: ENV, now: Time.current)
      @operator = operator
      @password = password.to_s
      @correlation_id = correlation_id
      @env = env
      @now = now
    end

    def call
      return failed_result(code: "delete_mode_disabled", message: "Delete mode is disabled.", reason: "disabled") unless delete_mode_enabled?
      return failed_result(code: "delete_mode_disabled", message: "Delete mode is not configured.", reason: "secret_missing") if delete_mode_secret.blank?
      return failed_result(code: "forbidden", message: "Password verification failed.", reason: "invalid_password") unless operator.authenticate(password)

      issued_token = SecureRandom.urlsafe_base64(48)
      expires_at = now + unlock_window
      unlock = DeleteModeUnlock.create!(
        operator: operator,
        token_digest: DeleteModeUnlock.digest_for(token: issued_token, secret: delete_mode_secret),
        expires_at: expires_at
      )

      record_granted_event(unlock:, expires_at:)
      Result.new(token: issued_token, expires_at: expires_at)
    end

    private

    attr_reader :correlation_id, :env, :now, :operator, :password

    def delete_mode_enabled?
      ActiveModel::Type::Boolean.new.cast(env["CULLARR_DELETE_MODE_ENABLED"])
    end

    def delete_mode_secret
      env["CULLARR_DELETE_MODE_SECRET"].to_s
    end

    def failed_result(code:, message:, reason:)
      record_denied_event(reason:)
      Result.new(error_code: code, error_message: message)
    end

    def record_granted_event(unlock:, expires_at:)
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.security.delete_unlock_granted",
        correlation_id: correlation_id,
        actor: operator,
        subject_type: "DeleteModeUnlock",
        subject_id: unlock.id,
        payload: {
          delete_mode_unlock_id: unlock.id,
          expires_at: expires_at.iso8601
        }
      )
    end

    def record_denied_event(reason:)
      AuditEvents::Recorder.record_without_subject!(
        event_name: "cullarr.security.delete_unlock_denied",
        correlation_id: correlation_id,
        actor: operator,
        subject_type: "DeleteModeUnlock",
        payload: {
          reason: reason
        }
      )
    end

    def unlock_window
      minutes = AppSetting.db_value_for("sensitive_action_reauthentication_window_minutes").to_i
      minutes = 15 if minutes <= 0
      minutes.minutes
    rescue ActiveRecord::ActiveRecordError, KeyError
      15.minutes
    end
  end
end
