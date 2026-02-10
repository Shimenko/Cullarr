module ApplicationCable
  class Connection < ActionCable::Connection::Base
    CABLE_OPERATOR_COOKIE = :cullarr_operator_id

    identified_by :current_operator

    def connect
      self.current_operator = find_verified_operator
    end

    private

    def find_verified_operator
      operator_id = cookies.signed[CABLE_OPERATOR_COOKIE]
      operator = Operator.find_by(id: operator_id)
      return operator if operator.present?

      reject_unauthorized_connection
    end
  end
end
