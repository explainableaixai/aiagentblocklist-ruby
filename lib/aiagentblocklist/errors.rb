# frozen_string_literal: true

module AiAgentBlocklist
  # Base class for everything this gem raises. +status+ is the HTTP status for
  # answers from the server and nil for local problems (token, file name,
  # network, JSON).
  class Error < StandardError
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end
  end

  # HTTP 404: the token or the file name is unknown.
  class NotFoundError < Error; end

  # HTTP 403: the subscription behind the token has ended or is paused.
  class AccessEndedError < Error; end

  # Any other non-2xx answer.
  class HttpError < Error; end

  # The token is missing or is not 32 letters and digits. Raised before any request.
  class TokenError < Error; end
end
