# frozen_string_literal: true

require_relative "aiagentblocklist/version"
require_relative "aiagentblocklist/errors"
require_relative "aiagentblocklist/entry"
require_relative "aiagentblocklist/blocklist"
require_relative "aiagentblocklist/client"

# Feed client for the AI Agent Blocklist (https://www.aiagentblocklist.com).
module AiAgentBlocklist
  class << self
    # A shared client built from AIAGENTBLOCKLIST_TOKEN on first use.
    def client
      @client ||= Client.new
    end

    attr_writer :client

    # Shortcut for AiAgentBlocklist.client.load_blocklist.
    def load_blocklist
      client.load_blocklist
    end
  end
end
