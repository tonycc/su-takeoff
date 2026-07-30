# src/api/api_error.rb
module SuTakeoff
  module Api
    class ApiError < StandardError
      attr_reader :status, :code, :details, :retryable, :body

      def initialize(message, status: nil, code: nil, details: nil, retryable: false, body: nil)
        super(message.to_s)
        @status = status
        @code = code
        @details = details
        @retryable = retryable
        @body = body
      end

      def retryable?
        !!@retryable
      end
    end
  end
end
