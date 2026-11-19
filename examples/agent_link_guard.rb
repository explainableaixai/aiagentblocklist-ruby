# frozen_string_literal: true

# A Rails controller concern that refuses user-submitted links to AI agent
# domains. Copy to app/controllers/concerns/agent_link_guard.rb.
#
#   class BookmarksController < ApplicationController
#     include AgentLinkGuard
#     guard_agent_links :url, only: %i[create update]
#   end
#
# The blocklist is read from storage/aab/aab_full.json (kept current by the
# rake task or the Sidekiq job) and reloaded when the file changes.

require "aiagentblocklist"

module AgentLinkGuard
  extend ActiveSupport::Concern

  MUTEX = Mutex.new

  class_methods do
    def guard_agent_links(*params_keys, **options)
      before_action(**options) { refuse_agent_links(params_keys) }
    end
  end

  def self.blocklist
    path = Rails.root.join("storage", "aab", "aab_full.json").to_s
    mtime = File.mtime(path)
    MUTEX.synchronize do
      if @loaded_at != mtime
        @list = AiAgentBlocklist::Blocklist.from_file(path)
        @loaded_at = mtime
      end
      @list
    end
  end

  private

  def refuse_agent_links(keys)
    flat = params.to_unsafe_h
    keys.each do |key|
      value = flat.dig(*key.to_s.split(".")) || flat[key]
      next unless value.is_a?(String) && !value.empty?

      entry = AgentLinkGuard.blocklist.check_domain(value)
      next unless entry

      render plain: "Links to #{entry.tool_name} (#{entry.agent_type}) are not allowed.", status: :unprocessable_entity
      return
    end
  end
end
