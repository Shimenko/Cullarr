module AuditEvents
  class Recorder
    class << self
      def record!(event_name:, correlation_id:, actor:, subject:, payload: {})
        AuditEvent.create!(
          operator: actor,
          event_name: event_name,
          subject_type: subject.class.name,
          subject_id: subject.id,
          correlation_id: correlation_id,
          payload_json: payload,
          occurred_at: Time.current
        )
      end

      def record_without_subject!(event_name:, correlation_id:, actor:, subject_type: nil, subject_id: nil, payload: {})
        AuditEvent.create!(
          operator: actor,
          event_name: event_name,
          subject_type: subject_type,
          subject_id: subject_id,
          correlation_id: correlation_id,
          payload_json: payload,
          occurred_at: Time.current
        )
      end
    end
  end
end
