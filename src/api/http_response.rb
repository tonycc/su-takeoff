# src/api/http_response.rb
module SuTakeoff
  module Api
    class HttpResponse
      attr_reader :status, :body, :headers

      def initialize(status:, body:, headers: {})
        @status = status.to_i
        @body = body
        @headers = headers || {}
      end

      def success?
        @status >= 200 && @status < 300
      end
    end
  end
end
