module Api
  module V1
    class BaseController < ApplicationController
      prepend_before_action :set_api_version_header

      private

      def set_api_version_header
        response.set_header("X-Cullarr-Api-Version", "v1")
      end
    end
  end
end
