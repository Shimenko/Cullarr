module Integrations
  class Error < StandardError
    attr_reader :details

    def initialize(message = nil, details: {})
      @details = details
      super(message)
    end
  end
end
